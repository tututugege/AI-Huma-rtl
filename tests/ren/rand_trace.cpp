// Constrained-random trace generator for the ren module: drives the *reference* Ren class (back-end/Ren.cpp) with
// a small ROB model around it so that every stimulus is legal for the C++ (free-list sanity asserts stay on), and
// records a trace with the same spec as scripts/record.sh. Purpose: reach corner cases real programs never produce:
// flush with/without commits, interrupt, exception commits with dest_en (ECALL/page-fault/illegal), mispredict
// with older no-dest commits, flush and mispredict in the same cycle, areg 32, free-list exhaustion, many
// branches per group. Build/run: see tests/ren/run_rand.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include "Ren.h"
#include "ren_fields.h"
using namespace ttg_io;

long long sim_time = 0;
void SimContext::run_commit_inst(InstEntry *, int) {}
void SimContext::run_difftest_inst(InstEntry *) {}
void SimContext::run_difftest_interrupt() {}

static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const std::string &n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

struct RobEnt { bool dest_en; int dest_areg, dest_preg, old_dest_preg; bool is_br; int br_id; };

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 100000;
  int areg_pool = argc > 4 ? atoi(argv[4]) : 6;   // small pool = many RAW/WAW collisions in a group
  int p_dest = argc > 5 ? atoi(argv[5]) : 70;     // % of instructions with a destination
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };

  SimContext ctx;
  Ren ren(&ctx);
  DecRenIO dec2ren; DecBroadcastIO dec; DisRenIO dis; RobBroadcastIO rob; RobCommitIO com;
  RenDecIO ren2dec; RenDisIO ren2dis;
  ren.in = {&dec2ren, &dec, &dis, &rob, &com};
  ren.out = {&ren2dec, &ren2dis};
  ren.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  std::deque<RobEnt> rq;           // in-flight (renamed, not committed) instructions, oldest first
  bool tag_live[MAX_BR_NUM] = {};  // tags of branches in rq
  int commit_p = 50;

  for (int c = 0; c < ncyc; c++) {
    if (c % 1500 == 0) { static const int pr[] = {2, 10, 40, 90}; commit_p = pr[R(4)]; }
    dec = {}; rob = {}; com = {}; dis = {}; dec2ren = {};
    // ---- commit side (applied to the model immediately) ----
    bool want_flush = P(1);
    bool interrupt = false;
    bool want_mispred = P(6);
    int ncommit = P(commit_p) ? R(9) : 0;
    if (ncommit > (int)rq.size()) ncommit = rq.size();
    if (want_mispred && !want_flush) {  // reclaiming commits and a mispredict never coincide (C++ sanity would fail)
      int k = 0; while (k < ncommit && !rq[k].dest_en) k++;
      ncommit = k;
    }
    bool flush_by_exc = false;
    for (int i = 0; i < ncommit; i++) {
      RobEnt e = rq.front(); rq.pop_front();
      if (e.is_br) tag_live[e.br_id] = false;
      auto &ce = com.commit_entry[i]; ce.valid = true; auto &u = ce.uop;
      u.dest_en = e.dest_en; u.dest_areg = e.dest_areg; u.dest_preg = e.dest_preg; u.old_dest_preg = e.old_dest_preg;
      u.type = e.is_br ? 4 : 3;
      if (P(4)) {  // exception commit (possibly with dest_en); nothing younger commits this cycle
        int k = R(5);
        u.page_fault_inst = k == 0; u.page_fault_load = k == 1; u.page_fault_store = k == 2; u.illegal_inst = k == 3;
        if (k == 4) u.type = 9;  // ECALL
        flush_by_exc = true; ncommit = i + 1;
      }
    }
    bool flush = want_flush || flush_by_exc;
    if (flush) interrupt = P(15);
    rob.flush = flush; rob.interrupt = interrupt;
    // ---- mispredict: pick an unresolved branch still in the ROB model (flush & mispred together: rare) ----
    bool mispred = want_mispred && (!flush || P(10));
    int mp_pos = -1;
    if (mispred) {
      std::vector<int> br;
      for (int i = 0; i < (int)rq.size(); i++) if (rq[i].is_br) br.push_back(i);
      if (br.empty()) mispred = false; else mp_pos = br[R(br.size())];
    }
    dec.mispred = mispred;
    if (mispred) dec.br_id = rq[mp_pos].br_id;
    auto brm = [&]() { uint64_t m = 0; int n = R(4); for (int i = 0; i < n; i++) m |= 1ull << R(MAX_BR_NUM); return m; };
    dec.clear_mask = P(35) ? brm() : 0;
    if (mispred) dec.clear_mask |= 1ull << dec.br_id;
    dis.ready = P(75) && rq.size() < 120;
    // ---- decode group (only sampled by Ren when ren2dec.ready) ----
    bool tag_used_now[MAX_BR_NUM] = {};
    for (int i = 0; i < DECODE_WIDTH; i++) {
      auto &u = dec2ren.uop[i];
      dec2ren.valid[i] = P(85);
      int tsel = R(100);
      u.type = tsel < 15 ? 4 : tsel < 22 ? 2 : tsel < 60 ? 3 : tsel < 70 ? 5 : tsel < 78 ? 6 : tsel < 80 ? 18 : R(20);
      bool br = (u.type == 4 || u.type == 2);
      u.dest_areg = P(8) ? 32 : P(80) ? 1 + R(areg_pool) : 1 + R(31);
      u.src1_areg = P(10) ? 0 : P(70) ? R(areg_pool + 1) : R(32);
      u.src2_areg = P(10) ? 0 : P(70) ? R(areg_pool + 1) : R(32);
      u.dest_en = P(p_dest);
      u.diag_val = rng(); u.src1_en = R(2); u.src2_en = R(2); u.is_atomic = R(2); u.src1_is_pc = R(2);
      u.src2_is_imm = R(2); u.func3 = R(8); u.func7 = R(128); u.imm = rng(); u.csr_idx = R(4096);
      u.ftq_idx = R(FTQ_SIZE); u.ftq_offset = R(16); u.ftq_is_last = R(2);
      u.page_fault_inst = P(2); u.illegal_inst = P(2);
      u.br_mask = rng() & rng();
      u.br_id = 0;
      if (br) {
        int t, tries = 0;
        do { t = 1 + R(MAX_BR_NUM - 1); }  /* tag 0 is reserved (C++ asserts mispred br_id != 0) */
        while ((tag_live[t] || tag_used_now[t]) && ++tries < 200);
        if (tag_live[t] || tag_used_now[t]) { br = false; u.type = 3; } else { tag_used_now[t] = true; u.br_id = t; }
      }
    }
    // the group is only sampled when Ren has no held group, so tags need only be unique against tag_live
    ren.comb_begin(); ren.comb_alloc(); ren.comb_rename(); ren.comb_fire(); ren.comb_pipeline();
    // record
    auto SI = [&](const char *n, int i, uint64_t v) { S(n, i, v); };
    for (int i = 0; i < DECODE_WIDTH; i++) {
      auto &u = dec2ren.uop[i];
      SI("dec2ren_valid", i, dec2ren.valid[i]);
#define DU(f) SI("dec2ren_uop_" #f, i, u.f)
      DU(diag_val); DU(dest_areg); DU(src1_areg); DU(src2_areg); DU(ftq_idx); DU(ftq_offset); DU(ftq_is_last);
      DU(type); DU(dest_en); DU(src1_en); DU(src2_en); DU(is_atomic); DU(src1_is_pc); DU(src2_is_imm); DU(func3);
      DU(func7); DU(imm); DU(br_id); DU(br_mask); DU(csr_idx); DU(page_fault_inst); DU(illegal_inst);
      auto &o = ren2dis.uop[i];
      SI("ren2dis_valid", i, ren2dis.valid[i]);
#define OU(f) SI("ren2dis_uop_" #f, i, o.f)
      OU(diag_val); OU(dest_areg); OU(ftq_idx); OU(ftq_offset); OU(ftq_is_last); OU(type); OU(dest_en); OU(src1_en);
      OU(src2_en); OU(is_atomic); OU(src1_is_pc); OU(src2_is_imm); OU(func3); OU(func7); OU(imm); OU(br_id);
      OU(br_mask); OU(csr_idx); OU(page_fault_inst); OU(illegal_inst); OU(dest_preg); OU(src1_preg); OU(src2_preg);
      OU(old_dest_preg);
      auto &ce = com.commit_entry[i]; auto &cu = ce.uop;
      SI("rob_commit_commit_entry_valid", i, ce.valid);
#define CU(f) SI("rob_commit_commit_entry_uop_" #f, i, cu.f)
      CU(dest_areg); CU(dest_preg); CU(old_dest_preg); CU(dest_en); CU(type); CU(page_fault_inst);
      CU(page_fault_load); CU(page_fault_store); CU(illegal_inst);
    }
    S("dec_bcast_mispred", 0, dec.mispred); S("dec_bcast_br_id", 0, dec.br_id);
    S("dec_bcast_clear_mask", 0, dec.clear_mask); S("dis2ren_ready", 0, dis.ready);
    S("rob_bcast_flush", 0, rob.flush); S("rob_bcast_interrupt", 0, rob.interrupt);
    S("ren2dec_ready", 0, ren2dec.ready);
    w.commit(c + 1, 0);
    // ---- model update ----
    if (flush) { rq.clear(); memset(tag_live, 0, sizeof tag_live); }
    else if (mispred) {
      while ((int)rq.size() > mp_pos + 1) { if (rq.back().is_br) tag_live[rq.back().br_id] = false; rq.pop_back(); }
    } else {
      for (int i = 0; i < DECODE_WIDTH; i++) {
        if (!(ren2dis.valid[i] && dis.ready)) continue;
        auto &o = ren2dis.uop[i];
        RobEnt e{(bool)o.dest_en, (int)o.dest_areg, (int)o.dest_preg, (int)o.old_dest_preg,
                 o.type == 4 || o.type == 2, (int)o.br_id};
        if (e.is_br) tag_live[e.br_id] = true;
        rq.push_back(e);
      }
    }
    ren.seq();
    sim_time++;
  }
  w.flush();
  return 0;
}
