// AXI interconnect + LLC statistics plugin (per tick). Loaded via TTG_REC_END (see axi-record-hook.md).
// Prints "AXS <key> <value>" lines at exit; aggregate with agg_stat.py (sum for counters, max for keys starting with max_).
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#define private public
#define protected public
#include "SimCpu.h"
#include "memsys_tap.h"
#include "axi_tap.h"
#undef private
#undef protected
using namespace axi_interconnect;

static std::map<std::string, uint64_t> C;
static uint64_t ncyc = 0, N = ~0ull;
static void mx(const std::string &k, uint64_t v) { auto &r = C[k]; if (v > r) r = v; }
static void ev(const std::string &k, uint64_t n = 1) { C[k] += n; }
static void fin() {
  for (auto &kv : C) std::printf("AXS %s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
}

static void ser(const AXI_LLC_ExtOut_t &e, std::vector<uint64_t> &v) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    v.push_back(e.upstream.read_req[i].ready); v.push_back(e.upstream.read_resp[i].valid);
    v.push_back(e.upstream.read_resp[i].id);
    for (int w = 0; w < MAX_READ_TRANSACTION_WORDS; ++w) v.push_back(e.upstream.read_resp[i].data.words[w]);
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
    v.push_back(e.upstream.write_req[i].ready); v.push_back(e.upstream.write_resp[i].valid);
    v.push_back(e.upstream.write_resp[i].id); v.push_back(e.upstream.write_resp[i].resp);
  }
  const auto &m = e.mem;
  v.push_back(m.invalidate_all_accepted); v.push_back(m.invalidate_line_accepted);
  v.push_back(m.read_req_valid); v.push_back(m.read_req_addr); v.push_back(m.read_req_size);
  v.push_back(m.read_req_mode2_ddr_aligned); v.push_back(m.read_req_id); v.push_back(m.read_resp_ready);
  v.push_back(m.write_req_valid); v.push_back(m.write_req_addr);
  for (int w = 0; w < MAX_WRITE_TRANSACTION_WORDS; ++w) v.push_back(m.write_req_data.words[w]);
  for (int b = 0; b < MAX_WRITE_TRANSACTION_BYTES; ++b) v.push_back(m.write_req_strobe.bytes[b]);
  v.push_back(m.write_req_size); v.push_back(m.write_req_mode2_ddr_aligned); v.push_back(m.write_req_id);
  v.push_back(m.write_resp_ready);
}
static bool eq_rd(const AxiTapReq &a, const AxiTapReq &b) {
  if (a.valid != b.valid) return false;
  return !a.valid || (a.addr == b.addr && a.size == b.size && a.id == b.id && a.bypass == b.bypass);
}
static bool eq_wr(const AxiTapWReq &a, const AxiTapWReq &b) {
  if (a.valid != b.valid) return false;
  if (!a.valid) return true;
  if (a.addr != b.addr || a.size != b.size || a.id != b.id || a.bypass != b.bypass || a.wstrb != b.wstrb) return false;
  return std::memcmp(a.wdata, b.wdata, sizeof a.wdata) == 0;
}

// table-read window tracking (reconstructed from the per-tick table_out stream)
struct Win { bool pend = false; uint32_t idx = 0; int age = 0; };
static Win win;
static uint64_t gtick = 0;
static AxiTapReq prevB_rd[TTG_AXI_RD];
static AxiTapWReq prevB_wr[TTG_AXI_WR];
static bool have_prev = false;

extern "C" void ttg_axi_tick(SimCpu *cpu, int tick) {
  static bool init = false;
  if (!init) { init = true; if (const char *e = std::getenv("AXS_N")) N = std::strtoull(e, 0, 0); std::atexit(fin); }
  auto &ic = cpu->axi_interconnect;
  auto &llc = ic.llc;
  const auto &regs = llc.io.regs;
  AxiTapTick &T = g_ttg_axi_tap.t[tick];
  ++gtick;
  ev("ticks");
  // ---------- Q1: ext_out of the two llc.comb() calls ----------
  {
    std::vector<uint64_t> a, b;
    ser(T.llc_ext_out1, a); ser(llc.io.ext_out, b);
    if (a == b) ev("llc_ext_out_whole_equal");
    else {
      ev("llc_ext_out_whole_differs");
      // which part differs? mem only vs upstream
      std::vector<uint64_t> am, bm;
      AXI_LLC_ExtOut_t x = T.llc_ext_out1, y = llc.io.ext_out;
      x.upstream = {}; y.upstream = {};
      ser(x, am); ser(y, bm);
      if (am != bm) {
        ev("llc_ext_out_MEM_differs");
        if (gtick > 16) ev("llc_ext_out_MEM_differs_LATE");
        const auto &p = T.llc_ext_out1.mem; const auto &q = llc.io.ext_out.mem;
        if (p.read_req_valid != q.read_req_valid) ev("mem_diff_read_req_valid");
        else if (p.read_req_valid && (p.read_req_addr != q.read_req_addr || p.read_req_id != q.read_req_id || p.read_req_size != q.read_req_size)) ev("mem_diff_read_req_payload");
        if (p.write_req_valid != q.write_req_valid) ev("mem_diff_write_req_valid");
        if (p.read_resp_ready != q.read_resp_ready) ev("mem_diff_read_resp_ready");
        if (p.write_resp_ready != q.write_resp_ready) ev("mem_diff_write_resp_ready");
        if (p.invalidate_all_accepted != q.invalidate_all_accepted || p.invalidate_line_accepted != q.invalidate_line_accepted) ev("mem_diff_invalidate");
        if (std::getenv("AXS_VERBOSE") && C["llc_ext_out_MEM_differs"] <= 6)
          std::fprintf(stderr, "MEMDIFF tick=%d gtick=%llu rdv %d/%d rdaddr %x/%x rdid %d/%d rdsize %d/%d rv_in lookup=%d mshr_slot_reqissued\n", tick, (unsigned long long)gtick, p.read_req_valid, q.read_req_valid, p.read_req_addr, q.read_req_addr, p.read_req_id, q.read_req_id, p.read_req_size, q.read_req_size, regs.lookup_valid_r);
      }
      else ev("llc_ext_out_only_upstream_differs");
      const auto &p = T.llc_ext_out1.upstream; const auto &q = llc.io.ext_out.upstream;
      for (int i = 0; i < NUM_READ_MASTERS; ++i) {
        if (p.read_req[i].ready != q.read_req[i].ready) ev("diff_read_req_ready");
        if (p.read_resp[i].valid != q.read_resp[i].valid) ev("diff_read_resp_valid");
      }
      for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
        if (p.write_req[i].ready != q.write_req[i].ready) ev("diff_write_req_ready");
        if (p.write_resp[i].valid != q.write_resp[i].valid) ev("diff_write_resp_valid");
      }
    }
  }
  // ---------- queue depths ----------
  mx("max_r_pending", ic.r_pending.size());
  mx("max_w_pending", ic.w_pending.size());
  for (int m = 0; m < NUM_WRITE_MASTERS; ++m) {
    mx("max_llc_upstream_write_q", ic.llc_upstream_write_q[m].size());
    mx("max_llc_write_resp_delay", ic.llc_write_resp_delay[m].size());
    mx("max_w_resp_queue", ic.w_resp_queue[m].size());
    mx("max_llc_write_q_count", regs.write_q_count_r[m]);
  }
  for (int m = 0; m < NUM_READ_MASTERS; ++m) mx("max_llc_read_resp_q_count", regs.read_resp_q_count_r[m]);
  mx("max_read_victim_wb_q_count", regs.read_victim_wb_q_count_r);
  { int nv = 0; for (int i = 0; i < MAX_OUTSTANDING; ++i) nv += regs.mshr[i].valid; mx("max_mshr_valid", nv); }
  { int nv = 0; for (int i = 0; i < NUM_READ_MASTERS; ++i) nv += (ic.r_pending.size() ? 0 : 0); (void)nv; }
  { std::map<int,int> per; for (auto &t : ic.r_pending) per[t.master_id]++;
    for (auto &kv : per) mx("max_r_pending_master" + std::to_string(kv.first), kv.second); }
  for (int m = 0; m < NUM_READ_MASTERS; ++m) { if (regs.read_resp_valid_r[m]) ev("read_resp_slot_busy_m" + std::to_string(m)); }
  if (ic.llc_core_req_stage_.valid) ev("core_stage_valid");
  // ---------- dead / unreachable checks ----------
  if (T.o2_mmio.arvalid) ev("MMIO_arvalid");
  if (T.o2_mmio.awvalid) ev("MMIO_awvalid");
  if (T.o2_mmio.wvalid) ev("MMIO_wvalid");
  if (T.d_mmio.rvalid || T.d_mmio.bvalid) ev("MMIO_slave_active");
  if (ic.ar_latched_mmio.valid || ic.aw_latched_mmio.valid || ic.w_active_mmio) ev("MMIO_latch_active");
  if (ic.w_active) ev("w_active_ddr");
  if (!ic.w_pending.empty()) ev("w_pending_nonempty");
  if (ic.llc_synth_read_resp_valid_) ev("synth_read_resp");
  if (ic.llc_mem_ignored_b_count_) ev("llc_mem_ignored_b");
  if (ic.llc_mem_write_resp_valid_) ev("llc_mem_write_resp_valid");
  if (ic.reconfig_pending_) ev("reconfig_pending");
  if (ic.llc_invalidate_all_req_ || ic.llc_invalidate_line_valid_) ev("invalidate_req");
  if (llc.io.ext_out.mem.invalidate_all_accepted || llc.io.ext_out.mem.invalidate_line_accepted) ev("invalidate_accepted");
  if (regs.victim_wb_valid_r) ev("llc_victim_wb_valid");
  for (int i = 0; i < MAX_OUTSTANDING; ++i) {
    if (regs.mshr[i].valid && regs.mshr[i].is_prefetch) ev("prefetch_mshr");
    if (regs.mshr[i].valid && regs.mshr[i].bypass) ev("mshr_bypass_valid_ticks");
    if (regs.mshr[i].valid && regs.mshr[i].is_write) ev("mshr_is_write");
    if (regs.mshr[i].valid && regs.mshr[i].victim_dirty) ev("mshr_victim_dirty");
  }
  if (regs.lookup_valid_r && regs.lookup_is_direct_mapped_r) ev("lookup_direct_mapped");
  if (regs.lookup_valid_r && regs.lookup_is_prefetch_r) ev("lookup_prefetch");
  if (regs.lookup_valid_r && regs.lookup_is_invalidate_r) ev("lookup_invalidate");
  if (regs.lookup_valid_r && regs.lookup_is_bypass_r) ev("lookup_bypass");
  if (regs.lookup_valid_r && regs.lookup_is_write_r) ev("lookup_write");
  if (regs.lookup_valid_r && regs.lookup_is_mode2_ddr_aligned_r) ev("lookup_mode2");
  for (int m = 0; m < NUM_WRITE_MASTERS; ++m) {
    const auto &c = regs.write_ctx[m];
    if (c.valid && c.bypass) ev("write_ctx_bypass");
    if (c.valid && c.victim_dirty) ev("write_ctx_victim_dirty");
  }
  // ---------- master-side facts (B = real per-tick requests) ----------
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    const auto &b = T.b_rd[i];
    if (b.valid) {
      ev("b_rd_valid_m" + std::to_string(i));
      if (tick != 0 && i != 1) ev("ERR_nondcache_rd_valid_on_tick>0");
      ev("b_rd_size_m" + std::to_string(i) + "_" + std::to_string(b.size));
      if (b.bypass) ev("b_rd_bypass_m" + std::to_string(i));
      mx("max_b_rd_id_m" + std::to_string(i), b.id);
    }
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
    const auto &b = T.b_wr[i];
    if (b.valid) {
      ev("b_wr_valid_m" + std::to_string(i));
      if (tick != 0 && i != 0) ev("ERR_nondcache_wr_valid_on_tick>0");
      ev("b_wr_size_m" + std::to_string(i) + "_" + std::to_string(b.size));
      if (b.bypass) ev("b_wr_bypass_m" + std::to_string(i));
      if (b.wstrb != ~0ull) ev("b_wr_partial_strobe_m" + std::to_string(i));
      mx("max_b_wr_id_m" + std::to_string(i), b.id);
      mx("max_b_wr_addr", b.addr);
    }
  }
  // ---------- A (stale at comb_outputs) vs previous tick's B ----------
  if (have_prev) {
    for (int i = 0; i < NUM_READ_MASTERS; ++i) {
      const bool dc = (i == 1);
      const AxiTapReq &a = T.a_rd[i];
      if (tick == 0 && i == 0) { // ICache drives its request before comb_outputs on tick 0
        if (eq_rd(a, T.b_rd[i])) ev("A_eq_B_same_tick_icache_t0"); else ev("A_ne_B_same_tick_icache_t0");
      } else if (dc && tick == 0) {
        if (!a.valid) ev("A_rd_dcache_t0_cleared"); else ev("A_rd_dcache_t0_NOT_cleared");
      } else if (dc) {
        if (eq_rd(a, prevB_rd[i])) ev("A_eq_prevB_rd_dcache"); else {
          ev("A_ne_prevB_rd_dcache");
          if (std::getenv("AXS_VERBOSE")) std::fprintf(stderr, "A!=prevB rd tick=%d A{v%d a%x s%d id%d b%d} prevB{v%d a%x s%d id%d b%d}\n", tick, a.valid, a.addr, a.size, a.id, a.bypass, prevB_rd[i].valid, prevB_rd[i].addr, prevB_rd[i].size, prevB_rd[i].id, prevB_rd[i].bypass);
        }
      } else {
        if (!a.valid) ev("A_rd_nondc_invalid"); else ev("A_rd_nondc_VALID_m" + std::to_string(i) + "_t" + (tick ? "n" : "0"));
      }
    }
    for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
      const AxiTapWReq &a = T.a_wr[i];
      if (i == 0 && tick == 0) { if (!a.valid) ev("A_wr_dcache_t0_cleared"); else ev("A_wr_dcache_t0_NOT_cleared"); }
      else if (i == 0) { if (eq_wr(a, prevB_wr[i])) ev("A_eq_prevB_wr_dcache"); else {
          ev("A_ne_prevB_wr_dcache");
          if (std::getenv("AXS_VERBOSE")) std::fprintf(stderr, "A!=prevB wr tick=%d A{v%d a%x s%d id%d strb%llx} prevB{v%d a%x s%d id%d strb%llx}\n", tick, a.valid, a.addr, a.size, a.id, (unsigned long long)a.wstrb, prevB_wr[i].valid, prevB_wr[i].addr, prevB_wr[i].size, prevB_wr[i].id, (unsigned long long)prevB_wr[i].wstrb);
        } }
      else { if (!a.valid) ev("A_wr_nondc_invalid"); else ev("A_wr_nondc_VALID"); }
    }
  }
  for (int i = 0; i < NUM_READ_MASTERS; ++i) prevB_rd[i] = T.b_rd[i];
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) prevB_wr[i] = T.b_wr[i];
  have_prev = true;
  // upstream data beyond 16 words must be zero
  for (int i = 0; i < NUM_READ_MASTERS; ++i)
    if (ic.read_ports[i].resp.valid)
      for (int w = TTG_AXI_RW; w < MAX_READ_TRANSACTION_WORDS; ++w) if (ic.read_ports[i].resp.data.words[w]) { ev("ERR_resp_data_beyond_16w"); break; }
  // ---------- Q2: LLC table-read windows ----------
  {
    const auto &to = llc.io.table_out;
    const bool rd = (to.data.enable && !to.data.write);
    const bool wr_any = (to.data.enable && to.data.write) || (to.meta.enable && to.meta.write) ||
                        (to.valid.enable && to.valid.write) || (to.repl.enable && to.repl.write);
    const bool inv = to.invalidate_all;
    const bool delivered = llc.io.lookup_in.data_valid;
    if (delivered) {
      ev("lookup_delivered");
      if (!win.pend) ev("ERR_delivery_without_request");
      else {
        if (win.age != 3) ev("ERR_delivery_latency_" + std::to_string(win.age));
        else ev("delivery_latency_is_3");
        win.pend = false;
      }
    }
    if (win.pend) win.age++;
    if (rd) {
      if (win.pend) ev("read_request_while_pending");
      // a write in the same tick as a read request?
      if (wr_any) ev("read_and_write_same_tick");
      win.pend = true; win.idx = to.data.index; win.age = 1;  // request tick = age 0, next tick age 1 ...
      ev("lookup_requests");
      if (to.meta.index != to.data.index || to.valid.index != to.data.index || to.repl.index != to.data.index)
        ev("ERR_table_index_mismatch");
    }
    // writes in the open window (ticks t+1, t+2; delivery tick t+3 comb_outputs happens before the write's seq)
    if (wr_any && win.pend && !rd) {
      const uint32_t widx = to.data.enable && to.data.write ? to.data.index
                           : to.meta.enable && to.meta.write ? to.meta.index
                           : to.valid.enable && to.valid.write ? to.valid.index : to.repl.index;
      if (widx == win.idx) ev("write_same_set_in_window_age" + std::to_string(win.age));
      else ev("write_other_set_in_window");
    }
    if (inv) ev("table_invalidate_all");
    if (wr_any) ev("table_write_ticks");
    if (to.data.enable && to.data.write) ev("table_data_writes");
    if (to.repl.enable && to.repl.write) ev("table_repl_writes");
  }
  // ---------- CPU-boundary tick-0 view of non-dcache masters ----------
  if (tick == 0) {
    if (ic.read_ports[0].req.valid) ev("icache_req_cycles");
    if (ic.read_ports[3].req.valid) ev("periph_rd_req_cycles");
    if (ic.write_ports[1].req.valid) ev("periph_wr_req_cycles");
  }
  if (tick == 15) {
    auto &ptw = cpu->mem_subsystem.ptw_block;
    mx("max_ptw_drop_resp_credit", ptw.cur_.walk_drop_resp_credit);
  }
  if (tick == 0) {
    ++ncyc;
    mx("max_ptw_drop_resp_credit", cpu->mem_subsystem.ptw_block.cur_.walk_drop_resp_credit);
    if (ncyc >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
  }
}

extern "C" void ttg_rec_cycle_end(SimCpu *cpu, uint64_t) { (void)cpu; }
extern "C" void ttg_rec_cycle(SimCpu *, uint64_t) {}
