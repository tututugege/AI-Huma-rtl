// Random-stimulus trace generator for the dispatch module: drives the *reference* Dispatch class
// (back-end/Dispatch.cpp) with constrained-random inputs and records a trace for spec/dispatch.io.
// Purpose: reach what real programs do not: issue-queue-full back-pressure (ready_num < lane demand on every IQ),
// SFENCE_VMA, tight LDQ/STQ limits, flush/mispredict storms, every AMO flavour. Build: tests/dispatch/run_rand.sh.
// The record block at the bottom is generated from the @ expressions of spec/dispatch.io (bt.X -> local X).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include "Dispatch.h"
#include "util.h"
#include "dispatch_fields.h"
using namespace ttg_io;

static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 50000;
  int p_tight = argc > 4 ? atoi(argv[4]) : 40;   // % of cycles with tight IQ/LSU resources
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };
  int next_preg = 0;
  auto alloc = [&]() { next_preg = next_preg % (PRF_NUM - 1) + 1; return next_preg; };
  auto brm = [&]() { uint64_t m = 0; int n = R(3); for (int i = 0; i < n; i++) m |= 1ull << R(8); return m; };
  const int amo_ops[] = {0, 1, 2, 3, 4, 8, 12, 16, 20, 24, 28};

  SimContext ctx;
  Dispatch dis(&ctx);
  RenDisIO ren2dis; DisRenIO dis2ren; RobDisIO rob2dis; IssDisIO iss2dis; LsuDisIO lsu2dis;
  PrfAwakeIO prf_awake; IssAwakeIO iss_awake; RobBroadcastIO rob_bcast; DecBroadcastIO dec_bcast;
  DisIssIO dis2iss; DisRobIO dis2rob; DisLsuIO dis2lsu;
  dis.in = {&ren2dis, &rob2dis, &iss2dis, &lsu2dis, &prf_awake, &iss_awake, &rob_bcast, &dec_bcast};
  dis.out = {&dis2ren, &dis2rob, &dis2iss, &dis2lsu};
  dis.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  for (int c = 0; c < ncyc; c++) {
    bool tight = P(p_tight);
    dec_bcast.mispred = P(6); dec_bcast.clear_mask = P(30) ? brm() : 0;
    rob_bcast.flush = P(2);
    rob2dis.ready = P(tight ? 70 : 95); rob2dis.empty = P(tight ? 40 : 15); rob2dis.stall = P(2);
    rob2dis.enq_idx = R(ROB_LINE_NUM); rob2dis.rob_flag = R(2);
    for (int q = 0; q < IQ_NUM; q++) iss2dis.ready_num[q] = tight ? R(10) : (P(80) ? 40 + R(60) : R(10));
    lsu2dis.stq_tail = R(STQ_SIZE); lsu2dis.stq_tail_flag = R(2);
    lsu2dis.stq_free = tight ? R(10) : (P(70) ? STQ_SIZE : R(STQ_SIZE + 1));
    lsu2dis.ldq_free = tight ? R(10) : (P(70) ? LDQ_SIZE : R(LDQ_SIZE + 1));
    for (int k = 0; k < MAX_LDQ_DISPATCH_WIDTH; k++) {
      lsu2dis.ldq_alloc_valid[k] = k < (int)lsu2dis.ldq_free;   // the LSU offers as many entries as it has free
      lsu2dis.ldq_alloc_idx[k] = R(LDQ_SIZE);
    }
    for (int k = 0; k < LSU_LOAD_WB_WIDTH; k++) { prf_awake.wake[k].valid = P(20); prf_awake.wake[k].preg = R(PRF_NUM); }
    for (int k = 0; k < MAX_WAKEUP_PORTS; k++) { iss_awake.wake[k].valid = P(25); iss_awake.wake[k].preg = R(PRF_NUM); }
    int ngroup = P(10) ? 0 : (P(50) ? DECODE_WIDTH : 1 + R(DECODE_WIDTH));
    for (int i = 0; i < DECODE_WIDTH; i++) {
      ren2dis.valid[i] = i < ngroup;
      auto &u = ren2dis.uop[i];
      u = {};
      int t = P(6) ? R(INST_TYPE_COUNT) : (P(50) ? (P(50) ? ADD : (P(50) ? LOAD : STORE)) : (P(40) ? BR : R(INST_TYPE_COUNT)));
      u.type = t;
      u.func7 = t == AMO ? (amo_ops[R(11)] << 2) | R(4) : R(128);
      u.func3 = R(8);
      u.dest_en = P(70); u.src1_en = P(70); u.src2_en = P(60);
      u.dest_areg = u.dest_en ? R(32) : 0; u.src1_areg = R(32); u.src2_areg = R(32);
      u.dest_preg = alloc(); u.old_dest_preg = R(PRF_NUM);
      auto recent = [&]() { return P(30) ? R(PRF_NUM) : ((next_preg - 1 - R(10) + 2 * (PRF_NUM - 1)) % (PRF_NUM - 1)) + 1; };
      u.src1_preg = recent(); u.src2_preg = recent();
      u.src1_busy = P(50); u.src2_busy = P(50);
      u.src1_is_pc = P(10); u.src2_is_imm = P(30);
      u.diag_val = rng(); u.imm = rng(); u.ftq_idx = R(FTQ_SIZE); u.ftq_offset = R(16); u.ftq_is_last = R(2);
      u.br_id = R(64); u.br_mask = brm(); u.csr_idx = R(4096); u.is_atomic = t == AMO;
      u.page_fault_inst = P(2); u.illegal_inst = P(2);
    }
    dis.comb_begin(); dis.comb_alloc(); dis.comb_wake(); dis.comb_dispatch(); dis.comb_fire(); dis.comb_pipeline();
    for (int i0=0;i0<8;i0++) S("ren2dis_valid", i0, (uint64_t)(ren2dis.valid[i0]));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_diag_val", i0, (uint64_t)(ren2dis.uop[i0].diag_val));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_dest_areg", i0, (uint64_t)(ren2dis.uop[i0].dest_areg));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src1_areg", i0, (uint64_t)(ren2dis.uop[i0].src1_areg));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_dest_preg", i0, (uint64_t)(ren2dis.uop[i0].dest_preg));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src1_preg", i0, (uint64_t)(ren2dis.uop[i0].src1_preg));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src2_preg", i0, (uint64_t)(ren2dis.uop[i0].src2_preg));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_old_dest_preg", i0, (uint64_t)(ren2dis.uop[i0].old_dest_preg));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_ftq_idx", i0, (uint64_t)(ren2dis.uop[i0].ftq_idx));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_ftq_offset", i0, (uint64_t)(ren2dis.uop[i0].ftq_offset));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_ftq_is_last", i0, (uint64_t)(ren2dis.uop[i0].ftq_is_last));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_type", i0, (uint64_t)(ren2dis.uop[i0].type));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_dest_en", i0, (uint64_t)(ren2dis.uop[i0].dest_en));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src1_en", i0, (uint64_t)(ren2dis.uop[i0].src1_en));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src2_en", i0, (uint64_t)(ren2dis.uop[i0].src2_en));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_is_atomic", i0, (uint64_t)(ren2dis.uop[i0].is_atomic));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src1_busy", i0, (uint64_t)(ren2dis.uop[i0].src1_busy));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src2_busy", i0, (uint64_t)(ren2dis.uop[i0].src2_busy));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src1_is_pc", i0, (uint64_t)(ren2dis.uop[i0].src1_is_pc));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_src2_is_imm", i0, (uint64_t)(ren2dis.uop[i0].src2_is_imm));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_func3", i0, (uint64_t)(ren2dis.uop[i0].func3));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_func7", i0, (uint64_t)(ren2dis.uop[i0].func7));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_imm", i0, (uint64_t)(ren2dis.uop[i0].imm));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_br_id", i0, (uint64_t)(ren2dis.uop[i0].br_id));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_br_mask", i0, (uint64_t)(ren2dis.uop[i0].br_mask));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_csr_idx", i0, (uint64_t)(ren2dis.uop[i0].csr_idx));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_page_fault_inst", i0, (uint64_t)(ren2dis.uop[i0].page_fault_inst));
    for (int i0=0;i0<8;i0++) S("ren2dis_uop_illegal_inst", i0, (uint64_t)(ren2dis.uop[i0].illegal_inst));
    S("rob2dis_ready", 0, (uint64_t)(rob2dis.ready));
    S("rob2dis_empty", 0, (uint64_t)(rob2dis.empty));
    S("rob2dis_stall", 0, (uint64_t)(rob2dis.stall));
    S("rob2dis_enq_idx", 0, (uint64_t)(rob2dis.enq_idx));
    S("rob2dis_rob_flag", 0, (uint64_t)(rob2dis.rob_flag));
    for (int i0=0;i0<5;i0++) S("iss2dis_ready_num", i0, (uint64_t)(iss2dis.ready_num[i0]));
    S("lsu2dis_stq_tail", 0, (uint64_t)(lsu2dis.stq_tail));
    S("lsu2dis_stq_tail_flag", 0, (uint64_t)(lsu2dis.stq_tail_flag));
    S("lsu2dis_stq_free", 0, (uint64_t)(lsu2dis.stq_free));
    S("lsu2dis_ldq_free", 0, (uint64_t)(lsu2dis.ldq_free));
    for (int i0=0;i0<8;i0++) S("lsu2dis_ldq_alloc_idx", i0, (uint64_t)(lsu2dis.ldq_alloc_idx[i0]));
    for (int i0=0;i0<8;i0++) S("lsu2dis_ldq_alloc_valid", i0, (uint64_t)(lsu2dis.ldq_alloc_valid[i0]));
    for (int i0=0;i0<4;i0++) S("prf_awake_wake_valid", i0, (uint64_t)(prf_awake.wake[i0].valid));
    for (int i0=0;i0<4;i0++) S("prf_awake_wake_preg", i0, (uint64_t)(prf_awake.wake[i0].preg));
    for (int i0=0;i0<15;i0++) S("iss_awake_wake_valid", i0, (uint64_t)(iss_awake.wake[i0].valid));
    for (int i0=0;i0<15;i0++) S("iss_awake_wake_preg", i0, (uint64_t)(iss_awake.wake[i0].preg));
    S("rob_bcast_flush", 0, (uint64_t)(rob_bcast.flush));
    S("dec_bcast_mispred", 0, (uint64_t)(dec_bcast.mispred));
    S("dec_bcast_clear_mask", 0, (uint64_t)(dec_bcast.clear_mask));
    S("dis2ren_ready", 0, (uint64_t)(dis2ren.ready));
    for (int i0=0;i0<8;i0++) S("dis2rob_dis_fire", i0, (uint64_t)(dis2rob.dis_fire[i0]));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_diag_val", i0, (uint64_t)(dis2rob.uop[i0].diag_val));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_dest_areg", i0, (uint64_t)(dis2rob.uop[i0].dest_areg));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_src1_areg", i0, (uint64_t)(dis2rob.uop[i0].src1_areg));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_dest_preg", i0, (uint64_t)(dis2rob.uop[i0].dest_preg));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_old_dest_preg", i0, (uint64_t)(dis2rob.uop[i0].old_dest_preg));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_ftq_idx", i0, (uint64_t)(dis2rob.uop[i0].ftq_idx));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_ftq_offset", i0, (uint64_t)(dis2rob.uop[i0].ftq_offset));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_ftq_is_last", i0, (uint64_t)(dis2rob.uop[i0].ftq_is_last));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_type", i0, (uint64_t)(dis2rob.uop[i0].type));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_dest_en", i0, (uint64_t)(dis2rob.uop[i0].dest_en));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_is_atomic", i0, (uint64_t)(dis2rob.uop[i0].is_atomic));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_func3", i0, (uint64_t)(dis2rob.uop[i0].func3));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_func7", i0, (uint64_t)(dis2rob.uop[i0].func7));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_imm", i0, (uint64_t)(dis2rob.uop[i0].imm));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_rob_idx", i0, (uint64_t)(dis2rob.uop[i0].rob_idx));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_stq_idx", i0, (uint64_t)(dis2rob.uop[i0].stq_idx));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_stq_flag", i0, (uint64_t)(dis2rob.uop[i0].stq_flag));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_expect_mask", i0, (uint64_t)(dis2rob.uop[i0].expect_mask));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_rob_flag", i0, (uint64_t)(dis2rob.uop[i0].rob_flag));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_page_fault_inst", i0, (uint64_t)(dis2rob.uop[i0].page_fault_inst));
    for (int i0=0;i0<8;i0++) S("dis2rob_uop_illegal_inst", i0, (uint64_t)(dis2rob.uop[i0].illegal_inst));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_valid", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].valid));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_dest_preg", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.dest_preg));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src1_preg", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src1_preg));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src2_preg", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src2_preg));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_ftq_idx", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.ftq_idx));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_ftq_offset", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.ftq_offset));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_is_atomic", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.is_atomic));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_dest_en", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.dest_en));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src1_en", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src1_en));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src2_en", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src2_en));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src1_busy", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src1_busy));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src2_busy", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src2_busy));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src1_is_pc", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src1_is_pc));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_src2_is_imm", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.src2_is_imm));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_func3", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.func3));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_func7", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.func7));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_imm", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.imm));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_br_id", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.br_id));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_br_mask", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.br_mask));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_csr_idx", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.csr_idx));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_rob_idx", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.rob_idx));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_stq_idx", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.stq_idx));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_stq_flag", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.stq_flag));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_ldq_idx", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.ldq_idx));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_rob_flag", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.rob_flag));
    for (int i0=0;i0<5;i0++) for (int i1=0;i1<8;i1++) S("dis2iss_req_uop_op", (i0)*8+i1, (uint64_t)(dis2iss.req[i0][i1].uop.op));
    for (int i0=0;i0<8;i0++) S("dis2lsu_alloc_req", i0, (uint64_t)(dis2lsu.alloc_req[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_br_mask", i0, (uint64_t)(dis2lsu.br_mask[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_func3", i0, (uint64_t)(dis2lsu.func3[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_rob_idx", i0, (uint64_t)(dis2lsu.rob_idx[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_rob_flag", i0, (uint64_t)(dis2lsu.rob_flag[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_stq_flag", i0, (uint64_t)(dis2lsu.stq_flag[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_ldq_alloc_req", i0, (uint64_t)(dis2lsu.ldq_alloc_req[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_ldq_br_mask", i0, (uint64_t)(dis2lsu.ldq_br_mask[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_ldq_idx", i0, (uint64_t)(dis2lsu.ldq_idx[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_ldq_rob_idx", i0, (uint64_t)(dis2lsu.ldq_rob_idx[i0]));
    for (int i0=0;i0<8;i0++) S("dis2lsu_ldq_rob_flag", i0, (uint64_t)(dis2lsu.ldq_rob_flag[i0]));
    w.commit(c + 1, 0);
    dis.seq();
  }
  w.flush();
  return 0;
}
