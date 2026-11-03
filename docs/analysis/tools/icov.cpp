// icache coverage plugin: counts events from the second tap (TTG_IC) per cycle. Env ICOV_N = max cycles.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#define private public
#define protected public
#include "SimCpu.h"
#include "front_tap.h"
#undef private
#undef protected
static std::map<std::string, uint64_t> C;
static uint64_t cnt = 0, N = ~0ull;
static void fin() { for (auto &kv : C) std::printf("ICOV %s %llu\n", kv.first.c_str(), (unsigned long long)kv.second); std::printf("ICOV cycles %llu\n", (unsigned long long)cnt); }
static void ev(const std::string &k) { C[k]++; }
extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t cycle) {
  static bool init = false;
  if (!init) { init = true; if (const char *e = std::getenv("ICOV_N")) N = std::strtoull(e, 0, 0); std::atexit(fin); }
  auto &T = g_ttg_ic_tap; auto &F = g_ttg_front_tap;
  ++cnt;
  if (T.calls == 0) { ev("calls0"); }
  if (T.calls == 1) ev("calls1");
  if (T.calls == 2) ev("calls2");
  if (T.calls == 0) { if (cnt >= N) { fin(); std::fflush(stdout); std::_Exit(0);} return; }
  auto &s1 = T.step[0];
  const char *sn[] = {"IDLE","SWAP_IN","WAIT_DC","DRAIN","CANCEL_WAIT"};
  if (T.in_itlb_flush) ev("itlb_flush");
  if (T.in_itlb_flush && !T.in_refetch) ev("itlb_flush_no_refetch");
  if (T.in_itlb_flush && T.itlb_translate_invoked) ev("itlb_flush_and_translate");
  if (T.in_fence_i) ev("fence_i");
  if (T.in_fence_i && !T.in_refetch) ev("fence_i_no_refetch");
  if (T.in_fence_i && T.in_itlb_flush) ev("fence_i_and_itlb_flush");
  if (T.in_refetch) ev("refetch");
  if (T.itlb_translate_invoked) { ev("itlb_translate"); ev(std::string("itlb_result_") + std::to_string(T.itlb_result)); }
  if (T.ptw_req_valid) ev("ptw_req");
  if (T.ptw_resp_consumed) ev("ptw_resp_consumed");
  if (T.ptw_flush) ev("ptw_flush");
  if (T.ptw_resp_valid) ev("ptw_resp_valid_in");
  if (T.ptw_resp_valid && T.ptw_resp_fault) ev("ptw_resp_fault_in");
  if (s1.o_page_fault && s1.o_resp_valid) ev("resp_page_fault");
  if (s1.o_resp_valid && s1.o_single_word) ev("resp_single_word");
  if (s1.o_mem_req_valid && s1.o_mem_req_bypass) ev("mem_req_uncached");
  if (s1.tw_we) ev("table_write");
  if (s1.tw_inv) ev("table_invalidate_all");
  if (T.dc_req_valid) ev("dc_req_valid_final");
  if (T.dc_resp_valid) { ev("dc_resp_valid"); if (T.dc_resp_retry) ev("dc_resp_retry"); else if (T.dc_resp_miss) ev("dc_resp_miss"); else ev("dc_resp_hit"); }
  if (T.mem_resp_valid) {
    ev("mem_resp_valid");
    bool can = (s1.regs_before.txid_canceled_mask >> T.mem_resp_id) & 1;
    bool inf = (s1.regs_before.txid_inflight_mask >> T.mem_resp_id) & 1;
    bool act = s1.regs_before.miss_txid_valid_r && s1.regs_before.miss_txid_r == T.mem_resp_id;
    if (can) ev("mem_resp_canceled"); else if (act) ev("mem_resp_active"); else if (!inf) ev("mem_resp_orphan");
    if (s1.regs_before.state == 1 && s1.regs_before.mem_axi_state == 0 && act && T.mem_req_accepted) ev("mem_resp_same_cycle_accept");
  }
  if (s1.regs_before.txid_canceled_mask) ev("txid_canceled_nonzero");
  { std::string k = std::string("state_") + sn[s1.regs_before.state] + "_axi" + std::to_string(s1.regs_before.mem_axi_state) + (T.in_refetch||T.in_fence_i ? "_kill" : ""); ev(k); }
  if (s1.regs_before.state == 3) ev("STATE_DRAIN_SEEN");
  if (s1.regs_before.lookup_pending_r) ev("LOOKUP_PENDING_SEEN");
  if (s1.regs_before.mem_axi_state == 1 && s1.regs_before.state != 1) ev("axi_busy_state_not_swapin");
  if (T.calls == 2) {
    auto &s2 = T.step[1]; auto &R1 = s1.regs_next; auto &R2 = s2.regs_next;
    ev(std::string("flush_R1_") + sn[R1.state] + "_axi" + std::to_string(R1.mem_axi_state) + (R1.miss_txid_valid_r ? "_txv" : "") + (R1.req_valid_r ? "_rv" : ""));
    ev(std::string("flush_R2_") + sn[R2.state]);
    if (s1.o_mem_req_valid && !s2.o_mem_req_valid) ev("flush_kills_mem_req");
    if (s1.o_dc_req_valid && !s2.o_dc_req_valid) ev("flush_kills_dc_req");
    if (s1.o_resp_valid) ev("flush_with_resp");
    if (s1.tw_we) ev("flush_with_table_write");
    if (R1.req_valid_r) ev("flush_R1_req_valid");
    if (s1.o_mem_resp_ready != s2.o_mem_resp_ready) ev("flush_changes_resp_ready");
    if (R2.txid_canceled_mask != R1.txid_canceled_mask) ev("flush_changes_canceled_mask");
    if (R2.txid_inflight_mask != R1.txid_inflight_mask) ev("flush_changes_inflight_mask");
    if (s2.regs_before.state != R1.state || s2.regs_before.req_valid_r != R1.req_valid_r) ev("ERR_step2_regs_before_differs");
    // compare step-2 mem-side inputs: same as step 1 (the model reads the same ports)
  }
  if (T.calls == 1 && T.in_fence_i) {}
  if (!T.mem_req_valid && s1.o_mem_req_valid && T.calls==1) ev("ERR_final_mem_req_differs");
  if (cnt >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
}
