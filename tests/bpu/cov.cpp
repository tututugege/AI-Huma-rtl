// BPU coverage / dead-code probe: a plugin for the instrumented reference simulator (refsim_tap).
// Reads the BPU's own start-of-cycle state through g_bpu_top and the cycle's transaction from bpu_seq_txn.
// usage: TTG_REC=cov.dylib build/simulator prog.bin ; env COV_N = cycles ; prints one "COV ..." line at exit.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#define private public
#define protected public
#include "SimCpu.h"
#include "front_tap.h"
#include "BPU/BPU.h"
#undef private
#undef protected
static uint64_t N = ~0ull, cyc = 0;
static uint64_t c_refetch, c_pred, c_pred_noready, c_upd_lane, c_upd_drop, c_upd_drop_bankconf, c_qmax, c_qfull_try;
static uint64_t c_can_send0, c_type[8], c_idir_taken, c_call, c_ret, c_ras_spec_max, c_ras_arch_max, c_ras_full_push;
static uint64_t c_tage_reset[8], c_alloc, c_lanes_both, c_refetch_with_upd, c_refetch_pred_ptab, c_sc_nonzero;
static uint64_t c_tage_upd[8], c_btb_upd[8], c_mispred_lane, c_spec_ne_arch, c_upd_same_cycle_pred;
static uint64_t c_type_same_slot_lanes, c_tc_write, c_tc_mode_write, c_bpu_nopred_cycles, c_ptab_we, c_reset_cnt_msb;
static void fin() {
  std::printf("COV cycles=%llu refetch=%llu pred=%llu pred_noready=%llu ptab_we=%llu upd_lane=%llu upd_drop=%llu qmax=%llu "
              "can_send0=%llu ras_spec_max=%llu ras_arch_max=%llu ras_full_push=%llu call=%llu ret=%llu idir_taken=%llu "
              "refetch_with_upd=%llu mispred_lane=%llu spec_ne_arch=%llu sc_nonzero=%llu type_same_slot=%llu\n",
              (unsigned long long)cyc, (unsigned long long)c_refetch, (unsigned long long)c_pred, (unsigned long long)c_pred_noready,
              (unsigned long long)c_ptab_we, (unsigned long long)c_upd_lane, (unsigned long long)c_upd_drop, (unsigned long long)c_qmax,
              (unsigned long long)c_can_send0, (unsigned long long)c_ras_spec_max, (unsigned long long)c_ras_arch_max,
              (unsigned long long)c_ras_full_push, (unsigned long long)c_call, (unsigned long long)c_ret, (unsigned long long)c_idir_taken,
              (unsigned long long)c_refetch_with_upd, (unsigned long long)c_mispred_lane, (unsigned long long)c_spec_ne_arch,
              (unsigned long long)c_sc_nonzero, (unsigned long long)c_type_same_slot_lanes);
  std::printf("COV types:"); for (int i = 0; i < 8; i++) std::printf(" %llu", (unsigned long long)c_type[i]);
  std::printf("\nCOV tage_upd/bank:"); for (int i = 0; i < 8; i++) std::printf(" %llu", (unsigned long long)c_tage_upd[i]);
  std::printf("\nCOV btb_upd/bank:"); for (int i = 0; i < 8; i++) std::printf(" %llu", (unsigned long long)c_btb_upd[i]);
  std::printf("\nCOV tage_reset_events/bank:"); for (int i = 0; i < 8; i++) std::printf(" %llu", (unsigned long long)c_tage_reset[i]);
  std::printf("\nCOV tc_write=%llu tc_mode_write=%llu\n", (unsigned long long)c_tc_write, (unsigned long long)c_tc_mode_write);
}
extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t) {
  static bool init = false;
  if (!init) { init = true; if (const char *e = std::getenv("COV_N")) N = std::strtoull(e, 0, 0); std::atexit(fin); }
  BPU_TOP &b = *g_bpu_top;
  auto &t = c->front.update_req_->bpu_seq_txn;
  const auto &inp = t.inp; const auto &rq = t.req;
  cyc++;
  if (inp.refetch) c_refetch++;
  if (!b.pc_can_send_to_icache) c_can_send0++;
  if (rq.going_to_do_pred) c_pred++;
  if (rq.out_regs.PTAB_write_enable) c_ptab_we++;
  if (!inp.icache_read_ready && !inp.refetch) c_pred_noready++;
  bool anyupd = false; bool bank_seen[8] = {};
  for (int i = 0; i < COMMIT_WIDTH; i++) {
    if (!inp.in_upd_valid[i]) continue;
    anyupd = true; c_upd_lane++;
    c_type[inp.in_actual_br_type[i] & 7]++;
    if (inp.in_actual_br_type[i] == BR_DIRECT && inp.in_actual_dir[i] != inp.in_pred_dir[i]) c_mispred_lane++;
    if (inp.in_actual_br_type[i] == BR_IDIRECT && inp.in_actual_dir[i]) c_idir_taken++;
    if (inp.in_actual_br_type[i] == BR_CALL) c_call++;
    if (inp.in_actual_br_type[i] == BR_RET) c_ret++;
    int bk = (inp.in_update_base_pc[i] >> 2) & 7;
    if (bank_seen[bk]) c_upd_drop++; bank_seen[bk] = true;
    if (inp.in_sc_used[i] || inp.in_loop_used[i] || inp.in_sc_sum[i] || inp.in_loop_hit[i] || inp.in_loop_pred[i]) c_sc_nonzero++;
  }
  if (anyupd && inp.refetch) c_refetch_with_upd++;
  for (int i = 0; i < BPU_BANK_NUM; i++) {
    if (b.q_count[i] > c_qmax) c_qmax = b.q_count[i];
    if (rq.tage_in[i].update_en) { c_tage_upd[i]++; if ((b.tage_inst[i]->reset_cnt_reg & 0x7ff) == 0) c_tage_reset[i]++; }
    if (rq.btb_in[i].upd_valid) c_btb_upd[i]++;
    if (rq.btb_req[i].tc_we_commit) c_tc_write++;
    if (rq.btb_req[i].tc_mode_we_commit) c_tc_mode_write++;
  }
  if (b.Spec_ras_count > c_ras_spec_max) c_ras_spec_max = b.Spec_ras_count;
  if (b.Arch_ras_count > c_ras_arch_max) c_ras_arch_max = b.Arch_ras_count;
  if (b.Arch_ras_count == RAS_DEPTH) c_ras_full_push++;
  if (std::memcmp(b.Spec_GHR, b.Arch_GHR, sizeof b.Spec_GHR)) c_spec_ne_arch++;
  if (cyc >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
}
