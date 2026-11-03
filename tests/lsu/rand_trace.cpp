// Random-stimulus trace generator for the lsu module: drives the *reference* RealLsu class (back-end/Lsu/RealLsu.cpp) with a
// small legal environment and records a trace for spec/lsu.io.  The environment is a miniature of everything around the LSU:
//   * ROB / Dispatch : a program-order list of memory instructions, branches and flush instructions; Dispatch allocates LDQ/STQ
//     entries exactly as Dispatch.cpp does (lsu2dis.ldq_alloc_*, stq_tail/flag/free, snapshot of the STQ tail for loads);
//   * Exu            : issues LD / STA / STD requests (each exactly once, after random operand delays, never for killed uops);
//   * branches       : unresolved-branch masks, out-of-order resolution, clear_mask, mispredict kills (LDQ/STQ by br_mask);
//   * ROB commit     : in-order, stores commit only after their STA write-back (STD sent); exceptions (page faults) and random
//                      "interrupt" flushes commit as a single instruction with rob_bcast.flush (never together with a mispredict);
//   * MMU            : hit / miss / page fault / no response, silent in flush and mispredict cycles (BackTop::comb_lsu_mmu);
//   * DCache         : latency, HIT / CONFLICT / MSHR_HIT / MSHR_FULL replays, mshr_fill pulses, stale responses after kills;
//   * peripheral     : one outstanding MMIO request, ready = !busy.
// The reference model's own Assert()s (not compiled with NDEBUG) check the legality of the stimulus: store commit order,
// STQ/LDQ allocation, response generation tags, ...
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <string>
#include "RealLsu.h"
#include "SimCpu.h"
#include "lsu_fields.h"
using namespace ttg_io;

long long sim_time = 0;
static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

enum Kind { K_LD, K_ST, K_LR, K_SC, K_AMO, K_BR, K_FLUSH };
struct Ent {
  Kind kind;
  int rob_idx, rob_flag;
  uint64_t br_mask = 0;   // unresolved older branches at dispatch
  int br_id = -1, resolve_at = 0;
  bool br_mispred = false, resolved = false;
  int ldq_idx = -1, stq_idx = -1, stq_flag = 0, snap_idx = 0, snap_flag = 0;
  uint32_t vaddr = 0, data = 0;
  int func3 = 2, dest = 0, ready_addr_at = 0, ready_data_at = 0, disp_cycle = 0;
  bool ld_sent = false, sta_sent = false, data_sent = false, ld_done = false, sta_done = false, pf = false;
  bool has_ld() const { return kind == K_LD || kind == K_LR || kind == K_AMO; }
  bool has_st() const { return kind == K_ST || kind == K_SC || kind == K_AMO; }
  bool complete() const {
    switch (kind) {
    case K_BR: return resolved;
    case K_FLUSH: return true;
    case K_LD: case K_LR: return ld_done;
    case K_ST: return sta_done && data_sent;
    case K_SC: return ld_done && data_sent;
    case K_AMO: return ld_done && sta_done && data_sent;
    }
    return false;
  }
};

struct DcLoad { int at; uint32_t req_id, data; int replay; uint32_t addr; };
struct DcStore { int at; uint32_t req_id; int replay; };

int main(int argc, char **argv) {
  const char *out_file = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 20000;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out_file, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };

  SimContext ctx;
  RealLsu lsu(&ctx);
  struct { PeripheralRespIO peripheral_resp; DcacheLsuIO dcache2lsu; } in;
  struct { PeripheralReqIO peripheral_req; LsuDcacheIO lsu2dcache; } out;
  RobCommitIO rob_commit; RobBroadcastIO rob_bcast; DecBroadcastIO dec_bcast; DisLsuIO dis2lsu; ExeLsuIO exe2lsu;
  LsuDisIO lsu2dis; LsuRobIO lsu2rob; LsuExeIO lsu2exe; LsuMMUIO lsu2mmu_io; MMULsuIO mmu2lsu_io; CsrStatusIO csr_status;
  lsu.in.rob_commit = &rob_commit; lsu.in.rob_bcast = &rob_bcast; lsu.in.dec_bcast = &dec_bcast; lsu.in.csr_status = &csr_status;
  lsu.in.dis2lsu = &dis2lsu; lsu.in.exe2lsu = &exe2lsu; lsu.in.peripheral_resp = &in.peripheral_resp;
  lsu.in.dcache2lsu = &in.dcache2lsu; lsu.in.mmu2lsu = &mmu2lsu_io;
  lsu.out.lsu2dis = &lsu2dis; lsu.out.lsu2rob = &lsu2rob; lsu.out.lsu2exe = &lsu2exe; lsu.out.peripheral_req = &out.peripheral_req;
  lsu.out.lsu2dcache = &out.lsu2dcache; lsu.out.lsu2mmu = &lsu2mmu_io;
  lsu.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  std::deque<Ent> rob;               // program order, front = oldest
  int head_idx = 0, head_flag = 0;   // ROB index/flag of rob.front()
  uint64_t unresolved = 0;           // branch tags in flight
  std::deque<DcLoad> dcl; std::deque<DcStore> dcs;
  std::deque<uint32_t> replay_lines;
  bool mmio_busy = false; int mmio_resp_at = 0;
  int phase = 0, phase_left = 0;

  auto tail_idx = [&]() { return (head_idx + (int)rob.size()) % ROB_NUM; };
  auto tail_flag = [&]() { return (head_idx + (int)rob.size()) >= ROB_NUM ? !head_flag : head_flag; };
  auto pick_addr = [&](int f3, bool mmio) {
    int sz = f3 == 0 || f3 == 4 ? 1 : f3 == 1 || f3 == 5 ? 2 : 4;
    uint32_t a = mmio ? 0x10000000u + 4 * R(8) : 0x80001000u + 64 * R(5) + 4 * R(16);
    return a + (sz == 1 ? R(4) : sz == 2 ? 2 * R(2) : 0);
  };
  auto advance_head = [&](int n) {
    head_idx += n;
    if (head_idx >= ROB_NUM) { head_idx -= ROB_NUM; head_flag ^= 1; }
  };

  for (int c = 1; c <= ncyc; c++) {
    if (phase_left-- <= 0) { phase = R(7); phase_left = 100 + R(500); }
    // 0 balanced, 1 commit stalled (queues fill), 2 slow MMU (miss/no response), 3 replay-heavy DCache, 4 branchy, 5 MMIO heavy, 6 flushy
    const int p_disp = phase == 1 ? 90 : 60, p_commit = phase == 1 ? 3 : 85, p_miss = phase == 2 ? 45 : 8, p_nomap = phase == 2 ? 30 : 3;
    const int p_replay = phase == 3 ? 45 : 8, p_br = phase == 4 ? 40 : 12, p_mmio = phase == 5 ? 45 : 5, p_flush = phase == 6 ? 4 : 0;
    const int p_resolve = phase == 4 ? 35 : 15, p_mispred = phase == 4 ? 35 : 12;

    // ---- lsu2dis (comb_cal / comb_lsu2dis / comb_lsu2rob read cur only) ----
    lsu.comb_cal(); lsu.comb_lsu2dis(); lsu.comb_lsu2rob();

    // ---- branch resolution (Idu::comb_branch): at most one mispredict, any number of clears ----
    dec_bcast = {};
    int mp_branch = -1;
    for (auto &e : rob) {
      if (e.kind != K_BR || e.resolved || e.resolve_at > c || !P(p_resolve * 2)) continue;
      if (e.br_mispred && mp_branch >= 0) continue;
      e.resolved = true; dec_bcast.clear_mask |= 1ull << e.br_id; unresolved &= ~(1ull << e.br_id);
      if (e.br_mispred) { mp_branch = e.br_id; dec_bcast.mispred = true; dec_bcast.br_mask = 1ull << e.br_id; dec_bcast.br_id = e.br_id; }
    }

    // ---- ROB commit (Rob::comb_commit) ----
    rob_commit = {}; rob_bcast = {};
    bool flush = false;
    std::vector<Ent> committed;
    bool commit_ok = !dec_bcast.mispred && !rob.empty() && rob.front().complete() && P(p_commit);
    if (commit_ok) {
      bool single = rob.front().pf || rob.front().kind == K_FLUSH || (p_flush && P(p_flush));
      if (single) {
        committed.push_back(rob.front()); rob.pop_front(); flush = true;
      } else {
        for (int k = 0; k < COMMIT_WIDTH && !rob.empty(); k++) {
          const Ent &e = rob.front();
          if (!e.complete() || e.pf || e.kind == K_FLUSH) break;
          committed.push_back(e); rob.pop_front();
          if (P(15)) break;
        }
      }
    }
    for (int i = 0; i < (int)committed.size(); i++) {
      auto &ce = rob_commit.commit_entry[i];
      const Ent &e = committed[i];
      ce.valid = true;
      ce.uop.type = e.kind == K_LD ? 5 : e.kind == K_ST ? 6 : e.kind == K_BR ? 4 : e.kind == K_FLUSH ? 7 : 18;
      ce.uop.func7 = (e.kind == K_LR ? 2 : e.kind == K_SC ? 3 : 0) << 2;
      ce.uop.stq_idx = e.stq_idx < 0 ? 0 : e.stq_idx;
      ce.uop.rob_idx = e.rob_idx;
    }
    rob_bcast.flush = flush;
    {
      // head_valid/head_incomplete: oldest valid entry and oldest incomplete entry of the (post-commit view of the) ROB head
      bool hv = false, hiv = false; int hi = 0, hii = 0;
      std::deque<Ent> view = rob;
      for (auto it = committed.rbegin(); it != committed.rend(); ++it) view.push_front(*it);   // state before this cycle's commit
      if (!view.empty()) { hv = true; hi = view.front().rob_idx; }
      for (auto &e : view) if (!e.complete()) { hiv = true; hii = e.rob_idx; break; }
      rob_bcast.head_valid = hv; rob_bcast.head_rob_idx = hi; rob_bcast.head_incomplete_valid = hiv; rob_bcast.head_incomplete_rob_idx = hii;
    }
    advance_head((int)committed.size());
    lsu.comb_stq_commit();

    // ---- Dispatch (Dispatch::comb_alloc): resources from lsu2dis ----
    dis2lsu = {};
    {
      int n_try = P(p_disp) ? 1 + R(8) : 0, load_cnt = 0, store_cnt = 0;
      if (dec_bcast.mispred || (flush && !P(6))) n_try = 0;   // real Dispatch does not allocate in these cycles
      for (int k = 0; k < n_try && (int)rob.size() < ROB_NUM - 2; k++) {
        Ent e; int r = R(100);
        e.kind = r < 36 ? K_LD : r < 62 ? K_ST : r < 62 + p_br / 2 ? K_BR : r < 90 ? K_LD : r < 92 ? K_LR : r < 94 ? K_SC : r < 96 ? K_AMO : K_FLUSH;
        if (p_br > 20 && r >= 62 && r < 80) e.kind = K_BR;
        if (e.kind == K_BR && (~unresolved) == 0) e.kind = K_LD;
        if (e.kind == K_FLUSH && !P(30)) e.kind = K_ST;
        bool nl = e.has_ld(), ns = e.has_st();
        if (nl && !(load_cnt < (int)lsu2dis.ldq_free && load_cnt < MAX_LDQ_DISPATCH_WIDTH && lsu2dis.ldq_alloc_valid[load_cnt])) break;
        if (ns && !(store_cnt < (int)lsu2dis.stq_free && store_cnt < MAX_STQ_DISPATCH_WIDTH)) break;
        e.rob_idx = tail_idx(); e.rob_flag = tail_flag(); e.disp_cycle = c;
        e.br_mask = unresolved & ~dec_bcast.clear_mask;
        static const int ldf[7] = {0, 1, 2, 4, 5, 2, 2}, stf[4] = {0, 1, 2, 2};
        e.func3 = e.kind == K_LD ? ldf[R(7)] : e.kind == K_ST ? stf[R(4)] : 2;
        e.dest = P(90) ? 1 + R(100) : 0;
        e.vaddr = pick_addr(e.func3, P(p_mmio) && (e.kind == K_LD || e.kind == K_ST));
        e.data = rng();
        e.ready_addr_at = c + 1 + R(4) * R(3); e.ready_data_at = c + 1 + R(5) * R(3);
        if (nl) {
          int pos = (int)lsu2dis.stq_tail + store_cnt;
          e.snap_idx = pos % STQ_SIZE; e.snap_flag = lsu2dis.stq_tail_flag ^ ((pos / STQ_SIZE) & 1);
          e.ldq_idx = lsu2dis.ldq_alloc_idx[load_cnt];
          dis2lsu.ldq_alloc_req[load_cnt] = true; dis2lsu.ldq_idx[load_cnt] = e.ldq_idx; dis2lsu.ldq_br_mask[load_cnt] = e.br_mask;
          dis2lsu.ldq_rob_idx[load_cnt] = e.rob_idx; dis2lsu.ldq_rob_flag[load_cnt] = e.rob_flag;
          load_cnt++;
        }
        if (ns) {
          int pos = (int)lsu2dis.stq_tail + store_cnt;
          e.stq_idx = pos % STQ_SIZE; e.stq_flag = lsu2dis.stq_tail_flag ^ ((pos / STQ_SIZE) & 1);
          dis2lsu.alloc_req[store_cnt] = true; dis2lsu.br_mask[store_cnt] = e.br_mask; dis2lsu.rob_idx[store_cnt] = e.rob_idx;
          dis2lsu.rob_flag[store_cnt] = e.rob_flag; dis2lsu.stq_flag[store_cnt] = e.stq_flag; dis2lsu.func3[store_cnt] = e.func3;
          store_cnt++;
        }
        if (e.kind == K_BR) {
          int id = 1 + R(BR_MASK_WIDTH - 1);
          while (!((~unresolved >> id) & 1)) id = 1 + R(BR_MASK_WIDTH - 1);
          e.br_id = id; unresolved |= 1ull << id;
          e.resolve_at = c + 2 + R(12); e.br_mispred = P(p_mispred);
        }
        rob.push_back(e);
      }
    }

    // ---- peripheral / DCache responses (set by MemSubsystem::comb_outputs before back.comb) ----
    in = {};
    {
      bool resp_now = mmio_busy && mmio_resp_at <= c;
      in.peripheral_resp.ready = !mmio_busy;
      if (resp_now) { in.peripheral_resp.is_mmio = true; in.peripheral_resp.mmio_rdata = rng(); mmio_busy = false; }
      int k = 0;
      for (auto it = dcl.begin(); it != dcl.end() && k < LSU_LDU_COUNT;) {
        if (it->at > c) { ++it; continue; }
        const auto &wd = lsu.cur.wait_dcache_ldq[it->req_id & (LDQ_SIZE - 1)];
        uint32_t gen = it->req_id >> LDQ_IDX_WIDTH;
        if (wd.valid && (uint32_t)wd.req_gen != gen) { it = dcl.erase(it); continue; }   // would trip the generation Assert
        auto &rp = in.dcache2lsu.resp_ports.load_resps[k++];
        rp.valid = true; rp.req_id = it->req_id; rp.data = it->data; rp.replay = (ReplayType)it->replay;
        if (it->replay >= 2) replay_lines.push_back(it->addr);
        it = dcl.erase(it);
      }
      k = 0;
      for (auto it = dcs.begin(); it != dcs.end() && k < LSU_STA_COUNT;) {
        if (it->at > c) { ++it; continue; }
        auto &rp = in.dcache2lsu.resp_ports.store_resps[k++];
        rp.valid = true; rp.req_id = it->req_id; rp.replay = (ReplayType)it->replay;
        it = dcs.erase(it);
      }
      if (P(phase == 3 ? 25 : 8)) {
        in.dcache2lsu.mshr_fill = true;
        in.dcache2lsu.mshr_fill_addr = !replay_lines.empty() && P(80) ? replay_lines[R(replay_lines.size())] : 0x80001000u + 64 * R(5);
        if (P(30) && !replay_lines.empty()) replay_lines.pop_front();
      }
    }
    lsu.comb_mmio_in(); lsu.comb_dcache2lsu_ldq(); lsu.comb_dcache2lsu_stq(); lsu.comb_lsu2exe();

    // ---- write-backs seen by Exu/ROB ----
    auto find = [&](int rob_idx) -> Ent * {
      for (auto &e : rob) if (e.rob_idx == rob_idx) return &e;
      return nullptr;
    };
    // Exu drops write-backs of uops killed this cycle (is_br_killed / rob flush)
    auto killed_now = [&](const LsuExeIO::LsuExeRespUop &u) {
      return flush || (dec_bcast.mispred && ((uint64_t)u.br_mask & (uint64_t)dec_bcast.br_mask));
    };
    for (int i = 0; i < LSU_LOAD_WB_WIDTH; i++) {
      if (!lsu2exe.wb_req[i].valid || killed_now(lsu2exe.wb_req[i].uop)) continue;
      const auto &u = lsu2exe.wb_req[i].uop;
      Ent *e = find(u.rob_idx);
      if (!e) continue;
      e->ld_done = true;
      if (u.page_fault_load || u.page_fault_store) e->pf = true;
    }
    for (int i = 0; i < LSU_STA_COUNT; i++) {
      if (!lsu2exe.sta_wb_req[i].valid || killed_now(lsu2exe.sta_wb_req[i].uop)) continue;
      const auto &u = lsu2exe.sta_wb_req[i].uop;
      Ent *e = find(u.rob_idx);
      if (!e) continue;
      e->sta_done = true;
      if (u.page_fault_store) e->pf = true;
    }

    // ---- Exu: LD / STA / STD requests ----
    exe2lsu = {};
    {
      int nld = 0, nsta = 0, nsdu = 0;
      uint64_t dead = dec_bcast.mispred ? (uint64_t)dec_bcast.br_mask : 0;
      for (auto &e : rob) {
        if ((e.br_mask & dead) || flush || e.disp_cycle >= c) continue;
        if (e.has_ld() && !e.ld_sent && e.ready_addr_at <= c && nld < LSU_LDU_COUNT && P(70)) {
          auto &r = exe2lsu.agu_req[nld++];
          r.valid = true; r.uop.op = encode_uop_type(UOP_LOAD); r.uop.result = e.vaddr; r.uop.dest_preg = e.dest; r.uop.func3 = e.func3;
          r.uop.is_atomic = e.kind != K_LD; r.uop.func7 = (e.kind == K_LR ? 2 : 0) << 2;
          r.uop.rob_idx = e.rob_idx; r.uop.rob_flag = e.rob_flag; r.uop.stq_idx = e.snap_idx; r.uop.stq_flag = e.snap_flag;
          r.uop.ldq_idx = e.ldq_idx;
          e.ld_sent = true;
        }
        if (e.has_st() && !e.sta_sent && e.ready_addr_at <= c && nsta < LSU_STA_COUNT && P(70)) {
          auto &r = exe2lsu.agu_req[LSU_LDU_COUNT + nsta++];
          r.valid = true; r.uop.op = encode_uop_type(UOP_STA); r.uop.result = e.vaddr; r.uop.dest_preg = e.dest; r.uop.func3 = e.func3;
          r.uop.is_atomic = e.kind != K_ST; r.uop.func7 = (e.kind == K_SC ? 3 : 0) << 2;
          r.uop.rob_idx = e.rob_idx; r.uop.rob_flag = e.rob_flag; r.uop.stq_idx = e.stq_idx; r.uop.stq_flag = e.stq_flag;
          e.sta_sent = true;
        }
        if (e.has_st() && !e.data_sent && e.ready_data_at <= c && nsdu < LSU_SDU_COUNT && P(70)) {
          auto &r = exe2lsu.sdu_req[nsdu++];
          r.valid = true; r.uop.op = encode_uop_type(UOP_STD); r.uop.result = e.data; r.uop.rob_idx = e.rob_idx; r.uop.rob_flag = e.rob_flag; r.uop.stq_idx = e.stq_idx;
          e.data_sent = true;
        }
      }
    }
    lsu.comb_exe2lsu(); lsu.comb_tlb_out();

    // ---- MMU (BackTop::comb_lsu_mmu): silent in flush / mispredict cycles ----
    mmu2lsu_io = {};
    if (!flush && !dec_bcast.mispred) {
      auto answer = [&](MMUReq &rq, MMUResp &rs) {
        if (!rq.valid || P(p_nomap)) return;
        rs.valid = true; rs.paddr = rq.vaddr; rs.entry_idx = rq.entry_idx; rs.wait_idx = rq.wait_idx;
        int r = R(100);
        rs.result = r < p_miss ? MMUResultType::MISS : r < p_miss + 2 ? MMUResultType::PAGE_FAULT : MMUResultType::HIT;
      };
      for (int i = 0; i < LSU_LDU_COUNT; i++) answer(lsu2mmu_io.ldq_req[i], mmu2lsu_io.ldq_resp[i]);
      for (int i = 0; i < LSU_STA_COUNT; i++) answer(lsu2mmu_io.stq_req[i], mmu2lsu_io.stq_resp[i]);
    }
    lsu.comb_tlb_in_ldq(); lsu.comb_tlb_in_stq(); lsu.comb_stlf();
    lsu.comb_dis2lsu(); lsu.comb_flush();
    lsu.comb_lsu2dcache_ldq(); lsu.comb_lsu2dcache_stq(); lsu.comb_mmio_out(); lsu.comb_check();

    // ---- record ----
#include "rand_record.inc"
    w.commit(c, 0);
    lsu.seq();

    // ---- environment update ----
    for (int i = 0; i < LSU_LDU_COUNT; i++) {
      const auto &p = out.lsu2dcache.req_ports.load_ports[i];
      if (!p.valid) continue;
      int rp = P(p_replay) ? 1 + R(3) : 0;
      dcl.push_back({c + 1 + R(phase == 3 ? 8 : 3), p.req_id, (uint32_t)rng(), rp, p.addr});
    }
    for (int i = 0; i < LSU_STA_COUNT; i++) {
      const auto &p = out.lsu2dcache.req_ports.store_ports[i];
      if (!p.valid) continue;
      dcs.push_back({c + 1 + R(phase == 3 ? 8 : 3), p.req_id, P(p_replay) ? 1 + R(3) : 0});
    }
    if (out.peripheral_req.is_mmio && !mmio_busy) { mmio_busy = true; mmio_resp_at = c + 1 + R(6); }

    // kills: mispredict (younger = br_mask hit, checked before the clear_mask is applied) and rob flush (all uncommitted)
    if (flush) {
      rob.clear(); unresolved = 0;
    } else if (dec_bcast.mispred) {
      while (!rob.empty() && (rob.back().br_mask & dec_bcast.br_mask)) {
        if (rob.back().kind == K_BR) unresolved &= ~(1ull << rob.back().br_id);
        rob.pop_back();
      }
    }
    for (auto &e : rob) e.br_mask &= ~dec_bcast.clear_mask;
  }
  return 0;
}
