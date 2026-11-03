// Random-stimulus trace generator for the isu module: drives the *reference* Isu class (back-end/Isu.cpp) with
// constrained-random inputs in BackTop's stage order and records a trace for spec/isu.io.
// Reaches what real programs do not: full queues (INT, STA, STD, BR), enqueue in flush / mispredict / clear cycles,
// many simultaneous wake-ups, MUL/DIV/FP delayed wake-ups killed by branch masks, all ops on all ports, FU-not-ready stalls.
//
// Legality constraints (all follow what Dispatch / Exu guarantee at the Isu boundary):
//  * per IQ the number of valid enqueue lanes <= ready_num (that is the Dispatch back-pressure rule), lanes may be sparse;
//  * an IQ only gets ops it supports (config.h GLOBAL_IQ_CONFIG; FP goes to IQ_INT like Dispatch does);
//  * fu_ready_mask bits are limited to the port capability, and DIV/FP bits are only offered while the reference
//    model's delayed wake-up slots cannot overflow (conservative in-flight tracking), mirroring the busy iterative units.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include "Isu.h"
#include "util.h"
#include "isu_fields.h"
using namespace ttg_io;

long long sim_time = 0;
static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 30000;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };

  SimContext ctx;
  Isu isu(&ctx);
  DisIssIO dis2iss; PrfAwakeIO prf_awake; ExeIssIO exe2iss; RobBroadcastIO rob_bcast; DecBroadcastIO dec_bcast;
  IssPrfIO iss2prf; IssDisIO iss2dis; IssAwakeIO iss_awake;
  isu.in = {&dis2iss, &prf_awake, &exe2iss, &rob_bcast, &dec_bcast};
  isu.out = {&iss2prf, &iss2dis, &iss_awake};
  isu.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  // ops per IQ (UopType values)
  const std::vector<int> iq_ops[IQ_NUM] = {
      {1, 1, 1, 1, 1, 6, 7, 8, 9, 10, 11, 12, 13, 14, 14, 15, 16, 17, 17},  // INT: ALU-ish, CSR, MUL, DIV, FP
      {UOP_LOAD}, {UOP_STA}, {UOP_STD}, {UOP_JUMP, UOP_BR, UOP_BR}};
  int div_busy[16] = {0}, fp_busy[16] = {0};  // conservative in-flight timers (cycles left) of iterative wake-up slots
  int phase = 0, phase_left = 0;
  const int HOT = 20;  // small preg pool so wake-ups and dependencies collide often

  for (int c = 0; c < ncyc; c++) {
    if (phase_left-- <= 0) { phase = R(5); phase_left = 100 + R(600); }
    // phase 0: balanced, 1: issue starved (queues fill), 2: drain (few enqueues), 3: storm of flush/mispredict, 4: wake-heavy
    int p_fu = phase == 1 ? 8 : 90, p_enq = phase == 2 ? 10 : (phase == 1 ? 90 : 60);
    int p_mis = phase == 3 ? 25 : 3, p_flush = phase == 3 ? 6 : 1;

    // ---- stage order of BackTop::comb ----
    isu.comb_begin();
    isu.comb_ready();
    for (int q = 0; q < IQ_NUM; q++)
      for (int l = 0; l < MAX_IQ_DISPATCH_WIDTH; l++) dis2iss.req[q][l] = {};
    for (int q = 0; q < IQ_NUM; q++) {
      int budget = iss2dis.ready_num[q];
      int want = P(p_enq) ? 1 + R(MAX_IQ_DISPATCH_WIDTH) : 0;
      for (int l = 0; l < MAX_IQ_DISPATCH_WIDTH && budget > 0 && want > 0; l++) {
        if (P(75)) {
          auto &r = dis2iss.req[q][l];
          r.valid = 1; budget--; want--;
          auto &u = r.uop;
          u.op = iq_ops[q][R(iq_ops[q].size())];
          u.dest_en = P(80); u.src1_en = P(75); u.src2_en = P(60);
          u.dest_preg = R(P(70) ? HOT : PRF_NUM); u.src1_preg = R(P(80) ? HOT : PRF_NUM); u.src2_preg = R(P(80) ? HOT : PRF_NUM);
          u.src1_busy = P(60); u.src2_busy = P(60);
          u.func7 = R(128); u.func3 = R(8); u.imm = rng(); u.ftq_idx = R(FTQ_SIZE); u.ftq_offset = R(16);
          u.is_atomic = P(5); u.src1_is_pc = P(10); u.src2_is_imm = P(30);
          u.br_id = R(BR_MASK_WIDTH); u.csr_idx = R(4096); u.rob_idx = R(ROB_NUM); u.rob_flag = R(2);
          u.stq_idx = R(STQ_SIZE); u.stq_flag = R(2); u.ldq_idx = R(LDQ_SIZE);
          u.br_mask = 0;
          int nb = P(60) ? R(4) : 0;
          for (int b = 0; b < nb; b++) u.br_mask |= 1ull << R(12);
        }
      }
    }
    for (int k = 0; k < LSU_LOAD_WB_WIDTH; k++) {
      prf_awake.wake[k].valid = P(phase == 4 ? 70 : 25);
      prf_awake.wake[k].preg = R(P(85) ? HOT : PRF_NUM);
    }
    rob_bcast.flush = P(p_flush);
    dec_bcast.mispred = P(p_mis);
    dec_bcast.br_mask = 0;
    if (dec_bcast.mispred) { int nb = 1 + R(2); for (int b = 0; b < nb; b++) dec_bcast.br_mask |= 1ull << R(12); }
    dec_bcast.clear_mask = 0;
    if (P(30)) { int nb = 1 + R(3); for (int b = 0; b < nb; b++) dec_bcast.clear_mask |= 1ull << R(12); }

    int div_free = 0, fp_free = 0;
    for (int i = 0; i < ISU_DIV_WAKE_SLOT_NUM; i++) div_free += div_busy[i] == 0;
    for (int i = 0; i < ISU_FP_WAKE_SLOT_NUM; i++) fp_free += fp_busy[i] == 0;
    for (int p = 0; p < ISSUE_WIDTH; p++) {
      uint64_t cap = get_port_capability(p), m = 0;
      for (int b = 0; b < MAX_UOP_TYPE; b++)
        if ((cap >> b) & 1) m |= 1ull << b;
      uint64_t mask = P(p_fu) ? m : (P(30) ? (m & rng()) : 0);
      if (mask & OP_MASK_DIV) { if (div_free > 0) div_free--; else mask &= ~OP_MASK_DIV; }
      if (mask & OP_MASK_FP) { if (fp_free > 0) fp_free--; else mask &= ~OP_MASK_FP; }
      exe2iss.fu_ready_mask[p] = mask;
    }

    isu.comb_issue();
    for (int i = 0; i < 16; i++) { if (div_busy[i] > 0) div_busy[i]--; if (fp_busy[i] > 0) fp_busy[i]--; }
    for (int p = 0; p < ISSUE_WIDTH; p++) {
      auto &e = iss2prf.iss_entry[p];
      if (!e.valid || !e.uop.dest_en) continue;
      if (e.uop.op == UOP_DIV) for (int i = 0; i < ISU_DIV_WAKE_SLOT_NUM; i++) if (!div_busy[i]) { div_busy[i] = DIV_MAX_LATENCY + 1; break; }
      if (e.uop.op == UOP_FP) for (int i = 0; i < ISU_FP_WAKE_SLOT_NUM; i++) if (!fp_busy[i]) { fp_busy[i] = 12; break; }
    }
    isu.comb_awake();
    isu.comb_calc_latency_next();
    isu.comb_enq();
    isu.comb_flush();

#include "rand_record.inc"
    w.commit(c + 3, 0);
    // a global flush empties the delayed wake-up slots in the model; the conservative timers just stay busy
    isu.seq();
    sim_time++;
  }
  return 0;
}
