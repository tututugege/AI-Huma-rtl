// Random-stimulus trace generator for exu_ctrl: drives the *reference* Exu class (back-end/Exu/Exu.cpp) together with the
// real FU classes under constrained-random inputs and records a trace in the same format/spec as scripts/record.sh.
// Purpose: reach what real programs rarely produce: MUL/DIV/FPU completion colliding with new issue, write-back port
// contention (several FUs complete on one port), flush / mispredict while FUs are in flight, several BRUs mispredicting
// in the same cycle (oldest wins), CSR slot starved by MUL, LSU write-back being killed.
// Build/run: tests/exu_ctrl/run_rand.sh
//
// Legality constraints (all follow what the rest of the machine guarantees):
//  * an instruction is only issued on a port when exe2iss.fu_ready_mask of that port has the bit of its op (Isu rule);
//  * the op belongs to the port's op set; rob_idx/rob_flag are a running age counter (distinct per instruction);
//  * br_mask uses tags from a small pool, a mispredict broadcast is one-hot of a pooled tag and its tag is part of the
//    same cycle's clear_mask (Idu: clear_mask contains every resolved branch including the mispredicted one);
//  * FP/MUL/DIV encodings are the ones the FU classes accept (their asserts stay unreachable);
//  * LSU write-back requests carry plausible data; sta write-back never writes a register (Lsu).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include <array>
#include "Exu.h"
#include "exu_ctrl_fields.h"
using namespace ttg_io;

long long sim_time = 0;
static long cov_flushed_winner, cov_port_collide[4], cov_multi_misp, cov_csr_we_re;

struct Bt {                      // the BackTop members the spec expressions use
  Exu *exu;
  PrfExeIO prf2exe;
  DecBroadcastIO dec_bcast;
  RobBroadcastIO rob_bcast;
  LsuExeIO lsu2exe;
  CsrExeIO csr2exe;
  CsrStatusIO csr_status;
  ExePrfIO exe2prf;
  ExeIssIO exe2iss;
  ExeCsrIO exe2csr;
  ExeLsuIO exe2lsu;
  ExuIdIO exu2id;
  ExuRobIO exu2rob;
};

static void record(Bt &bt, ttg::TraceWriter<decltype(kFields)> &w) {
#include "rand_record.inc"
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 40000;
  int p_issue = argc > 4 ? atoi(argv[4]) : 60;     // % chance a port with room gets an instruction
  int p_flush = argc > 5 ? atoi(argv[5]) : 2;      // % ROB flush
  int p_misp = argc > 6 ? atoi(argv[6]) : 8;       // % branch mispredict broadcast
  int mix = argc > 7 ? atoi(argv[7]) : 0;          // 0: all ops, 1: favour MUL/DIV/FP/CSR (port 0..3 contention)
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };

  SimContext ctx;
  Exu exu(&ctx);
  Bt bt;
  bt.exu = &exu;
  exu.in.prf2exe = &bt.prf2exe; exu.in.dec_bcast = &bt.dec_bcast; exu.in.rob_bcast = &bt.rob_bcast;
  exu.in.lsu2exe = &bt.lsu2exe; exu.in.csr2exe = &bt.csr2exe; exu.in.csr_status = &bt.csr_status;
  exu.out.exe2prf = &bt.exe2prf; exu.out.exe2iss = &bt.exe2iss; exu.out.exe2csr = &bt.exe2csr;
  exu.out.exe2lsu = &bt.exe2lsu; exu.out.exu2id = &bt.exu2id; exu.out.exu2rob = &bt.exu2rob;
  exu.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  const int TAGS = 12;            // branch tag pool
  auto brm = [&]() { uint64_t m = 0; int n = R(4); for (int i = 0; i < n; i++) m |= 1ull << R(TAGS); return m; };
  uint64_t age = 0;               // running instruction age -> rob_idx / rob_flag
  std::vector<int> ops_of_port[ISSUE_WIDTH];
  for (int p = 0; p < ISSUE_WIDTH; p++)
    for (int op = 0; op < MAX_UOP_TYPE; op++) if (GLOBAL_ISSUE_PORT_CONFIG[p].support_mask >> op & 1) ops_of_port[p].push_back(op);

  for (int c = 0; c < ncyc; c++) {
    // ---- external inputs of this cycle (Idu / Rob / Lsu / Csr)
    bt.rob_bcast = {}; bt.dec_bcast = {}; bt.lsu2exe = {}; bt.csr2exe = {};
    bt.rob_bcast.flush = P(p_flush);
    if (P(p_misp)) {
      int tag = R(TAGS);
      bt.dec_bcast.mispred = true; bt.dec_bcast.br_id = tag; bt.dec_bcast.br_mask = 1ull << tag;
      bt.dec_bcast.clear_mask = (1ull << tag) | (P(30) ? brm() : 0);
    } else if (P(25)) {
      bt.dec_bcast.clear_mask = brm();
    }
    bt.csr2exe.rdata = (uint32_t)rng();
    for (int i = 0; i < LSU_LOAD_WB_WIDTH; i++) if (P(25)) {
      auto &e = bt.lsu2exe.wb_req[i]; auto &u = e.uop;
      e.valid = true; u.diag_val = rng(); u.result = rng(); u.dest_preg = R(PRF_NUM); u.br_mask = brm();
      u.rob_idx = R(ROB_NUM); u.dest_en = P(80); u.page_fault_load = P(5); u.page_fault_store = P(3); u.op = UOP_LOAD;
    }
    for (int i = 0; i < LSU_STA_COUNT; i++) if (P(25)) {
      auto &e = bt.lsu2exe.sta_wb_req[i]; auto &u = e.uop;
      e.valid = true; u.diag_val = rng(); u.result = rng(); u.br_mask = brm(); u.rob_idx = R(ROB_NUM);
      u.page_fault_store = P(3); u.op = UOP_STA; u.dest_en = false;
    }
    // ---- Exu cycle (BackTop::comb order)
    exu.comb_begin();
    exu.comb_to_csr();
    exu.comb_exec();
    exu.comb_ready();
    // coverage / claim checks (stderr summary): winners are never flushed or killed; arbitration and BRU conflicts happen
    for (int f = 0; f < TOTAL_FU_COUNT; f++) {
      auto &o = exu.in.fu2exu->entry[f];
      if (o.complete && (bt.rob_bcast.flush || (bt.dec_bcast.mispred && (o.inst.br_mask & bt.dec_bcast.br_mask)))) cov_flushed_winner++;
    }
    for (int p = 0; p < 4; p++) {
      int n = 0;
      for (auto &e : exu.port_mappings[p].entries) n += exu.in.fu2exu->entry[e.fu_idx].complete;
      if (n > 1) cov_port_collide[p]++;
    }
    { int nb = 0; for (int i = 0; i < BRU_NUM; i++) nb += bt.exu2rob.entry[IQ_BR_PORT_BASE + i].valid && bt.exu2rob.entry[IQ_BR_PORT_BASE + i].uop.mispred;
      if (nb > 1) cov_multi_misp++; }
    if (bt.exe2csr.we && bt.exe2csr.re) cov_csr_we_re++;
    // Isu: issue only what the ready mask allows
    bt.prf2exe = {};
    for (int p = 0; p < ISSUE_WIDTH; p++) {
      uint64_t mask = bt.exe2iss.fu_ready_mask[p];
      std::vector<int> ok;
      for (int op : ops_of_port[p]) if (mask >> op & 1) ok.push_back(op);
      if (ok.empty() || !P(p_issue)) continue;
      int op = ok[R(ok.size())];
      if (mix == 1) { std::vector<int> pref; for (int o : ok) if (o == UOP_MUL || o == UOP_DIV || o == UOP_FP || o == UOP_CSR) pref.push_back(o); if (!pref.empty() && P(70)) op = pref[R(pref.size())]; }
      auto &e = bt.prf2exe.iss_entry[p]; auto &u = e.uop;
      e.valid = true;
      u.op = op; u.pc = rng() & ~3u; u.ftq_pred_taken = R(2); u.ftq_next_pc = rng() & ~3u; u.dest_preg = R(PRF_NUM);
      u.src1_rdata = P(15) ? (P(50) ? 0 : 0xffffffffu) : (uint32_t)rng(); u.src2_rdata = P(15) ? (P(50) ? 0 : 0xffffffffu) : (uint32_t)rng();
      u.ftq_idx = R(FTQ_SIZE); u.ftq_offset = R(16); u.is_atomic = P(10); u.dest_en = P(80); u.src1_en = P(80); u.src2_en = P(80);
      u.src1_is_pc = R(2); u.src2_is_imm = R(2); u.func3 = R(8); u.func7 = R(128); u.imm = (uint32_t)rng();
      u.br_id = R(TAGS); u.br_mask = brm(); u.csr_idx = R(4096);
      u.rob_idx = age % ROB_NUM; u.rob_flag = (age / ROB_NUM) & 1; age++;
      u.stq_idx = R(STQ_SIZE); u.stq_flag = R(2); u.ldq_idx = R(LDQ_SIZE);
      if (op == UOP_MUL) u.func3 = R(4);
      if (op == UOP_DIV) { u.func3 = 4 + R(4); if (P(20)) u.src2_rdata = 0; }
      if (op == UOP_CSR) { static const int f3[] = {1, 2, 3, 5, 6, 7}; u.func3 = f3[R(6)]; if (P(30)) u.imm = 0; if (P(30)) u.dest_preg = 0; }
      if (op == UOP_FP) {
        static const int f7[] = {0, 1, 2, 3, 4, 8, 12, 0x2C, 0x10, 0x14, 0x50, 0x70, 0x60, 0x68};
        int s = R(14); u.func7 = f7[s]; static const int rm[] = {0, 1, 2, 3, 4, 7}; u.func3 = rm[R(6)];
        if (u.func7 == 0x10) u.func3 = R(3);
        if (u.func7 == 0x14) u.func3 = R(2);
        if (u.func7 == 0x50) u.func3 = R(3);
        if (u.func7 == 0x70) u.func3 = 1;
        u.imm = (u.imm & ~0x1Fu) | R(2);
        if (u.func7 == 0x2C || u.func7 == 0x70) u.imm &= ~0x1Fu;
      }
    }
    exu.comb_pipeline();
    record(bt, w);
    w.commit(c + 1, 0);
    exu.seq();
    sim_time++;
  }
  w.flush();
  fprintf(stderr, "cov: flushed_winner=%ld collide p0..3=%ld/%ld/%ld/%ld multi_mispred=%ld csr_we&re=%ld\n", cov_flushed_winner,
          cov_port_collide[0], cov_port_collide[1], cov_port_collide[2], cov_port_collide[3], cov_multi_misp, cov_csr_we_re);
  return 0;
}
