// Front-end coverage + boundary-consistency plugin (uses the front_tap; refsim only).
// Per cycle it (1) updates event counters, (2) runs an independent standalone FIFO model for each of the four
// FIFOs, fed ONLY with the proposed module-boundary signals, and checks that it reproduces the recorded outputs
// (read valid / head tag / size flags). Prints "COV key value" lines at exit (or after CHK_N cycles).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#define private public
#define protected public
#include "SimCpu.h"
#include "front_tap.h"
#undef private
#undef protected

static std::map<std::string, uint64_t> C;
static uint64_t N = ~0ull, cnt = 0;
#define CNT(k) (C[k]++)
#define CNTIF(c, k) do { if (c) C[k]++; } while (0)
#define MAXV(k, v) do { auto &r = C[k]; if ((uint64_t)(v) > r) r = (v); } while (0)

// ---- standalone FIFO model (semantics = "clear -> push -> pop", read only when non-empty) ------------------
template <typename T> struct FifoModel {
  std::deque<T> q;
  size_t cap;
  const char *name;
  // returns false on mismatch of rd_valid
  void step(bool clear, bool rd_en, bool wr_en, const T &wdata, bool &rd_valid, T &rdata) {
    const bool had = !clear && !q.empty();
    rd_valid = rd_en && had;
    if (rd_valid) rdata = q.front();
    if (clear) q.clear();
    if (wr_en) q.push_back(wdata);
    if (rd_valid) q.pop_front();
  }
};
static FifoModel<uint32_t> M_fa{{}, 16, "fa"};
struct Tag { uint32_t a, b; bool d; bool operator==(const Tag &o) const { return a == o.a && b == o.b && d == o.d; } };
static FifoModel<Tag> M_in{{}, 16, "inst"}, M_pt{{}, 16, "ptab"}, M_fb{{}, 32, "f2b"};
static std::map<std::string, uint64_t> MISM;
static void mism(const char *k) { MISM[k]++; if (MISM[k] <= 3) std::fprintf(stderr, "MISMATCH %s at cycle %llu\n", k, (unsigned long long)cnt); }

static void fin() {
  for (auto &kv : C) std::printf("COV %s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
  for (auto &kv : MISM) std::printf("COV MISMATCH_%s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
  std::printf("COV cycles %llu\n", (unsigned long long)cnt);
}

extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t cycle) {
  static bool init = false;
  if (!init) { init = true; if (const char *e = std::getenv("CHK_N")) N = std::strtoull(e, 0, 0); std::atexit(fin); }
  const FrontTap &t = g_ttg_front_tap;
  ++cnt;
  const auto &in = c->front.in;
  if (t.count == 0) { CNT("tap_empty_cycles"); return; }
  // ---------------- events -------------------------------------------------------------------------
  C["tap_count_last"] = t.count;
  CNTIF(in.reset, "ev_in_reset");
  CNTIF(t.global_reset, "ev_global_reset");
  CNTIF(in.refetch, "ev_backend_refetch");
  CNTIF(t.predecode_refetch_q, "ev_predecode_refetch_applied");
  CNTIF(in.refetch && t.predecode_refetch_q, "ev_backend_and_predecode_refetch_same_cycle");
  CNTIF(t.do_predecode_flush, "ev_checker_flush");
  CNTIF(in.itlb_flush, "ev_itlb_flush");
  CNTIF(in.fence_i, "ev_fence_i");
  CNTIF(!in.FIFO_read_enable, "ev_backend_stall_no_read_enable");
  CNTIF(t.bpu_stall, "ev_bpu_stall");
  CNTIF(t.bpu_stall && t.full_q[0], "ev_bpu_stall_fetch_addr_full");
  CNTIF(t.bpu_stall && t.full_q[2], "ev_bpu_stall_ptab_full");
  CNTIF(t.bpu_out.icache_read_valid && t.bpu_can_run, "ev_bpu_issue");
  CNTIF(t.bpu_out.PTAB_write_enable, "ev_bpu_ptab_write_enable");
  CNTIF(t.bpu_out.PTAB_write_enable != t.bpu_out.icache_read_valid, "ev_bpu_ptab_we_ne_icache_valid");
  CNTIF(t.bpu_out.mini_flush_req, "dead_bpu_mini_flush_req");
  CNTIF(t.bpu_out.mini_flush_correct, "dead_bpu_mini_flush_correct");
  CNTIF(t.bpu_out.two_ahead_valid, "dead_bpu_two_ahead_valid");
  CNTIF(t.bpu_out.update_queue_full, "ev_bpu_update_queue_full");
  CNTIF(t.can_bypass_fetch_to_icache, "ev_bypass_fetch_to_icache");
  CNTIF(t.can_bypass_icache_to_predecode, "ev_bypass_icache_to_predecode_opportunity");
  CNTIF(t.use_icache_to_predecode_bypass, "ev_bypass_icache_to_predecode_used");
  CNTIF(t.can_bypass_front2back_to_output, "ev_bypass_front2back_to_output");
  CNTIF(t.saved_ptab_out.dummy_entry, "dead_ptab_dummy_entry_read");
  CNTIF(t.ptab_req.push_dummy_en, "dead_ptab_dummy_push");
  CNTIF(t.icache_ready == 0, "ev_icache_not_ready");
  CNTIF(t.icache_out.icache_read_complete, "ev_icache_resp");
  CNTIF(t.icache_out.icache_read_complete && t.icache_slot0_data_valid == 0, "ev_icache_resp_but_slot0_invalid");
  CNTIF(t.icache_out.perf_miss_event, "ev_icache_miss_event");
  CNTIF(t.icache_out.perf_miss_busy, "ev_icache_miss_busy");
  CNTIF(t.icache_out.perf_req_blocked, "ev_icache_req_blocked");
  CNTIF(t.icache_out.perf_itlb_miss, "ev_itlb_miss");
  CNTIF(t.icache_out.perf_itlb_fault, "ev_itlb_fault");
  CNTIF(t.icache_out.perf_itlb_retry, "ev_itlb_retry");
  CNTIF(t.icache_slot0_data_valid && !t.global_reset && !t.global_refetch && t.full_q[1] && !t.use_icache_to_predecode_bypass,
        "ev_icache_data_arrives_inst_fifo_full(data lost?)");
  {
    bool pf = false, partial = false, anyv = false;
    for (int i = 0; i < FETCH_WIDTH; i++) {
      if (t.icache_slot0_data_valid) {
        pf |= t.icache_out.page_fault_inst[i];
        anyv |= t.icache_out.inst_valid[i];
        if (!t.icache_out.inst_valid[i]) partial = true;
      }
    }
    CNTIF(pf, "ev_icache_page_fault_group");
    CNTIF(t.icache_slot0_data_valid && partial, "ev_icache_partial_group(inst_valid has 0 lanes)");
    CNTIF(t.icache_slot0_data_valid && !anyv, "ev_icache_group_all_invalid");
  }
  if (t.predecode_can_run) {
    CNT("ev_predecode_run");
    int ty[4] = {0, 0, 0, 0};
    for (int i = 0; i < FETCH_WIDTH; i++) {
      if (t.saved_fifo_out.inst_valid[i]) ty[t.saved_fifo_out.predecode_type[i] & 3]++;
      if (t.checker_in.predecode_type[i] != 0 && t.checker_in.predict_dir[i] != t.checker_out.predict_dir_corrected[i])
        CNT("ev_checker_dir_corrected_lane");
    }
    CNTIF(ty[1], "ev_predecode_has_cond_branch"); CNTIF(ty[2], "ev_predecode_has_jalr"); CNTIF(ty[3], "ev_predecode_has_jal");
    bool jal_taken_pred_nt = false;
    for (int i = 0; i < FETCH_WIDTH; i++)
      if (t.checker_in.predecode_type[i] == PREDECODE_JAL && !t.checker_in.predict_dir[i]) jal_taken_pred_nt = true;
    CNTIF(jal_taken_pred_nt, "ev_checker_jal_predicted_not_taken");
    CNTIF(t.checker_out.predecode_flush_enable, "ev_checker_flush_enable");
    CNTIF(t.saved_fifo_out.page_fault_inst[0] || t.saved_fifo_out.page_fault_inst[1], "ev_predecode_pagefault_group(lane0/1)");
  }
  CNTIF(t.front2back_read_enable && t.saved_front2back_fifo_out.front2back_FIFO_valid, "ev_f2b_deliver");
  CNTIF(t.front2back_read_enable && !t.saved_front2back_fifo_out.front2back_FIFO_valid && !t.use_front2back_output_bypass, "ev_f2b_bubble");
  CNTIF(t.f2b_rd.size == FRONT2BACK_FIFO_SIZE, "ev_f2b_full_at_start");
  CNTIF(t.ptab_rd.size >= PTAB_SIZE - 1, "ev_ptab_ge_cap_minus1_at_start");
  CNTIF(t.ptab_rd.size == PTAB_SIZE, "ev_ptab_full_at_start");
  CNTIF(t.inst_rd.size == INSTRUCTION_FIFO_SIZE, "ev_inst_full_at_start");
  CNTIF(t.fa_rd.size >= FETCH_ADDR_FIFO_SIZE - 1, "ev_fa_ge_cap_minus1_at_start");
  MAXV("max_size_fa", t.fa_rd.size); MAXV("max_size_inst", t.inst_rd.size);
  MAXV("max_size_ptab", t.ptab_rd.size); MAXV("max_size_f2b", t.f2b_rd.size);
  // multi-op combinations per FIFO
  CNTIF(t.fetch_addr_req.push_en && t.fetch_addr_req.pop_en, "fifo_fa_push_and_pop");
  CNTIF(t.inst_req.push_en && t.inst_req.pop_en, "fifo_inst_push_and_pop");
  CNTIF(t.ptab_req.push_write_en && t.ptab_req.pop_en, "fifo_ptab_push_and_pop");
  CNTIF(t.front2back_req.push_en && t.front2back_req.pop_en, "fifo_f2b_push_and_pop");
  CNTIF(t.fetch_addr_req.clear_fifo && t.fetch_addr_req.push_en, "fifo_fa_clear_and_push");
  CNTIF(t.inst_req.clear_fifo && t.inst_req.push_en, "fifo_inst_clear_and_push");
  CNTIF(t.ptab_req.clear_ptab && t.ptab_req.push_write_en, "fifo_ptab_clear_and_push");
  CNTIF(t.front2back_req.clear_fifo && t.front2back_req.push_en, "fifo_f2b_clear_and_push");
  // pop of an empty queue combined with a push (would need FIFO-internal write-through)
  CNTIF(t.fa_rd.size == 0 && t.fetch_addr_req.pop_en, "fifo_fa_pop_when_empty_at_start");
  CNTIF(t.inst_rd.size == 0 && t.inst_req.pop_en, "fifo_inst_pop_when_empty_at_start");
  CNTIF(t.ptab_rd.size == 0 && t.ptab_req.pop_en, "fifo_ptab_pop_when_empty_at_start");
  CNTIF(t.f2b_rd.size == 0 && t.front2back_req.pop_en, "fifo_f2b_pop_when_empty_at_start");
  CNTIF(t.fetch_addr_req.push_en && t.fetch_addr_req.pop_en && t.fa_rd.size == 0, "fifo_fa_write_through_would_be_needed");
  CNTIF(t.inst_req.pop_en && t.inst_req.push_en, "fifo_inst_pop_and_push_same_cycle");
  // front2back_hold glue (SimCpu level)
  CNTIF(c->front2back_hold_1.valid[0] || c->front2back_hold_1.valid[1], "ev_front2back_hold_loaded");
  // ---------------- structural invariants (checked every cycle) --------------------------------------------
  if (t.bpu_out.PTAB_write_enable != (t.bpu_out.icache_read_valid && t.bpu_can_run) && !t.global_reset) mism("inv_ptab_we_eq_issue");
  if (!t.global_refetch && !t.global_reset && t.fetch_addr_req.push_en != t.ptab_req.push_write_en) mism("inv_fa_push_eq_ptab_push");
  if (t.global_refetch && t.fetch_addr_req.push_en) CNT("ev_fa_push_on_refetch_cycle");
  if (t.inst_rd.size > t.ptab_rd.size) mism("inv_inst_size_le_ptab_size");
  if (t.fa_rd.size > t.ptab_rd.size) mism("inv_fa_size_le_ptab_size");
  if (t.ptab_rd.size > PTAB_SIZE - 1) mism("inv_ptab_size_le_cap_minus1");
  if (t.fetch_addr_req.pop_en && t.icache_out.icache_read_complete == 0 && t.icache_in.icache_read_valid == 0) mism("inv_fa_pop_implies_icache_req");
  if (t.icache_in.icache_read_valid != (bool)t.fa_out0.read_valid) mism("inv_icache_req_eq_fa_read");
  if (t.predecode_can_run != (t.inst_fifo_read_enable && !t.saved_ptab_out.dummy_entry)) mism("inv_predecode_run_eq_read_enable");
  if (t.ptab_req.pop_en != t.inst_req.pop_en) mism("inv_ptab_pop_eq_inst_pop");
  // ---------------- flag redundancy: latch == f(size) ---------------------------------------------------
  {
    const bool fa_full = t.fa_rd.size >= FETCH_ADDR_FIFO_SIZE - 1, fa_empty = t.fa_rd.size == 0;
    const bool in_full = t.inst_rd.size == INSTRUCTION_FIFO_SIZE, in_empty = t.inst_rd.size == 0;
    const bool pt_full = t.ptab_rd.size >= PTAB_SIZE - 1, pt_empty = t.ptab_rd.size == 0;
    const bool fb_full = t.f2b_rd.size == FRONT2BACK_FIFO_SIZE, fb_empty = t.f2b_rd.size == 0;
    if (t.full_q[0] != fa_full || t.empty_q[0] != fa_empty) mism("latch_vs_size_fa");
    if (t.full_q[1] != in_full || t.empty_q[1] != in_empty) mism("latch_vs_size_inst");
    if (t.full_q[2] != pt_full || t.empty_q[2] != pt_empty) mism("latch_vs_size_ptab");
    if (t.full_q[3] != fb_full || t.empty_q[3] != fb_empty) mism("latch_vs_size_f2b");
  }
  // ---------------- standalone FIFO models ---------------------------------------------------------------
  bool rv;
  {  // fetch_address FIFO
    uint32_t rd = 0;
    M_fa.step(t.global_reset || t.global_refetch, t.fetch_addr_fifo_read_enable_slot0, t.fetch_addr_req.push_en,
              t.fetch_addr_req.push_data, rv, rd);
    if (rv != (bool)t.fa_out0.read_valid) mism("fa_read_valid");
    else if (rv && rd != t.fa_out0.fetch_address) mism("fa_read_data");
    if ((M_fa.q.size() >= FETCH_ADDR_FIFO_SIZE - 1) != (bool)t.next_full[0] || M_fa.q.empty() != (bool)t.next_empty[0]) mism("fa_next_flags");
    if (t.fetch_addr_req.pop_en != (bool)rv) mism("fa_pop_en");
  }
  {  // instruction FIFO (read result is only consumed when not bypassed)
    Tag w{t.inst_req.push_entry.pc[0], t.inst_req.push_entry.seq_next_pc, false}, r{};
    M_in.step(t.global_reset || t.global_refetch, t.inst_fifo_read_enable, t.inst_req.push_en, w, rv, r);
    if (t.inst_req.pop_en != (bool)rv) mism("inst_pop_en");
    if (rv && !t.use_icache_to_predecode_bypass) {
      if (r.a != t.saved_fifo_out.pc[0] || r.b != t.saved_fifo_out.seq_next_pc) mism("inst_read_data");
    }
    if ((M_in.q.size() == INSTRUCTION_FIFO_SIZE) != (bool)t.next_full[1] || M_in.q.empty() != (bool)t.next_empty[1]) mism("inst_next_flags");
  }
  {  // PTAB: read_enable = stage-3 read OR icache->predecode bypass read
    const PTAB_entry &e = t.ptab_req.push_write_entry;
    Tag w{e.predict_base_pc[0], e.predict_next_fetch_address, (bool)e.dummy_entry}, r{};
    const bool rd_en = t.ptab_read_enable || t.can_bypass_icache_to_predecode;
    M_pt.step(t.global_reset || t.global_refetch, rd_en, t.ptab_req.push_write_en, w, rv, r);
    if (t.ptab_req.pop_en != (bool)rv) mism("ptab_pop_en");
    if (rv) {
      if (r.a != t.saved_ptab_out.predict_base_pc[0] || r.b != t.saved_ptab_out.predict_next_fetch_address) mism("ptab_read_data");
    }
    if ((M_pt.q.size() >= PTAB_SIZE - 1) != (bool)t.next_full[2] || M_pt.q.empty() != (bool)t.next_empty[2]) mism("ptab_next_flags");
  }
  {  // front2back FIFO: flushed only by RESET or BACKEND refetch (not by the predecode refetch)
    const auto &e = t.front2back_req.push_entry;
    Tag w{e.predict_base_pc[0], e.predict_next_fetch_address_corrected, false}, r{};
    M_fb.step(t.global_reset || in.refetch, t.front2back_read_enable, t.front2back_req.push_en, w, rv, r);
    if (t.front2back_req.pop_en != (bool)rv) mism("f2b_pop_en");
    if (rv) {
      if (r.a != t.saved_front2back_fifo_out.predict_base_pc[0] ||
          r.b != t.saved_front2back_fifo_out.predict_next_fetch_address_corrected) mism("f2b_read_data");
    }
    if ((M_fb.q.size() == FRONT2BACK_FIFO_SIZE) != (bool)t.next_full[3] || M_fb.q.empty() != (bool)t.next_empty[3]) mism("f2b_next_flags");
  }
  // front.out must equal either the FIFO head or the bypass
  {
    const auto &o = c->front.out;
    const auto &src = (t.saved_front2back_fifo_out.front2back_FIFO_valid || !t.use_front2back_output_bypass)
                          ? t.saved_front2back_fifo_out : t.bypass_front2back_fifo_out;
    if (o.FIFO_valid != src.front2back_FIFO_valid) mism("out_valid");
    else if (o.FIFO_valid && (o.pc[0] != src.predict_base_pc[0] || o.predict_next_fetch_address != src.predict_next_fetch_address_corrected))
      mism("out_data");
  }
  if (cnt >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
}
