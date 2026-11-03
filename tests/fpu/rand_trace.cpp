// Constrained-random trace generator for the fpu module: drives the *reference* FPUSoftfloat object (Berkeley softfloat
// behind IterativeFU) through the same per-cycle call sequence as Exu (comb_begin, comb_ctrl, comb_issue, [consume
// decision], comb_consume, seq) and records spec/fpu.io fields.
//   usage: rand_trace <out.trc> <seed> <cycles> <profile 0..3>
// Stimulus legality (Exu.cpp): consume only for a complete FU output; en may be asserted any cycle (the FU ignores it while
// busy); in.inst holds garbage when en=0 (stale slot in the real Exu). Instruction encodings are the legal F-extension ones
// (single precision: func7[1:0]=0; rs2 selector 0/1 for fcvt; func3 per instruction); rounding modes 0..4, 7 and rarely 5.
// Profiles: 0 = mostly completes, few flushes; 1 = frequent flushes/clears with a small br_mask universe (kill/clear
// paths); 2 = consume rarely (long waits, back-to-back en while complete); 3 = everything busy, long ops (div/sqrt) heavy.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include "golden.h"
#include "fpgen.h"
#include "fpu_fields.h"
using namespace ttg_io;
long long sim_time = 0;
static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, uint64_t v) { tw->set(ids.at(n), 0, v); }

struct Dut : FPUSoftfloat { Dut() : FPUSoftfloat("FPU", 1, 10) {} };

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  long ncyc = argc > 3 ? atol(argv[3]) : 300000;
  int prof = argc > 4 ? atoi(argv[4]) : 0;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  FpGen g(seed);
  static Dut fu;
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);
  //                       0    1    2    3
  const int p_en[4]      = {300, 500, 600, 800};   // per mille: en this cycle
  const int p_consume[4] = {800, 600, 120, 500};   // consume a completed output
  const int p_flush[4]   = { 10, 120,  30,  40};
  const int p_clear[4]   = { 50, 250,  50,  50};
  // instruction mix weights per class (C_ADD..C_CLASS)
  static const int wt[4][C_NUM] = {
    {30, 10, 30, 8, 6, 5, 4, 5, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3},
    {20, 10, 20, 8, 8, 5, 5, 5, 5, 4, 3, 3, 4, 4, 4, 4, 4, 4},
    {20, 10, 20, 10, 10, 5, 5, 5, 5, 3, 3, 3, 3, 3, 3, 3, 3, 3},
    { 5,  3,  5, 35, 35, 5, 5, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1}};
  static const FpInstr kInstr[C_NUM] = {
    {0x00, 0, 0, C_ADD}, {0x04, 0, 0, C_SUB}, {0x08, 0, 0, C_MUL}, {0x0C, 0, 0, C_DIV}, {0x2C, 0, 0, C_SQRT},
    {0x60, 0, 0, C_CVT_W}, {0x60, 0, 1, C_CVT_WU}, {0x68, 0, 0, C_CVT_SW}, {0x68, 0, 1, C_CVT_SWU},
    {0x10, 0, 0, C_SGNJ}, {0x10, 1, 0, C_SGNJN}, {0x10, 2, 0, C_SGNJX}, {0x14, 0, 0, C_MIN}, {0x14, 1, 0, C_MAX},
    {0x50, 2, 0, C_EQ}, {0x50, 1, 0, C_LT}, {0x50, 0, 0, C_LE}, {0x70, 1, 0, C_CLASS}};
  int wsum = 0; for (int i = 0; i < C_NUM; i++) wsum += wt[prof][i];
  auto sparse_mask = [&](int nbits, int universe) -> uint64_t {
    uint64_t m = 0;
    for (int i = 0; i < nbits; i++) m |= 1ull << (g.P(850) ? g.R(universe) : g.R(64));
    return m;
  };
  long n_comp = 0, n_cons = 0;
  for (long cyc = 0; cyc < ncyc; cyc++) {
    AbstractFU::FuInput &in = fu.in;
    in = AbstractFU::FuInput();
    in.en = g.P(p_en[prof]);
    // instruction (garbage when !en)
    int pick = g.R(wsum), cls = 0;
    for (; cls < C_NUM; cls++) { if (pick < wt[prof][cls]) break; pick -= wt[prof][cls]; }
    FpInstr ins = kInstr[cls];
    uint32_t a = g.f32(), b = g.P(500) ? g.f32_related(a) : g.f32();
    bool uses_rm = cls <= C_SQRT || cls == C_CVT_W || cls == C_CVT_WU || cls == C_CVT_SW || cls == C_CVT_SWU;
    if (uses_rm) ins.func3 = g.rm_any();
    if (cls == C_CVT_W || cls == C_CVT_WU) a = g.f32_for_int();
    if (cls == C_CVT_SW || cls == C_CVT_SWU) a = g.i32();
    in.inst.op = UOP_FP;
    in.inst.func7 = ins.func7; in.inst.func3 = ins.func3;
    in.inst.imm = (g.r32() & ~0x1Fu) | ins.imm;          // only imm & 0x1F is read by the reference
    in.inst.src1_rdata = a; in.inst.src2_rdata = b;
    in.inst.br_mask = g.P(300) ? 0 : sparse_mask(1 + g.R(3), prof == 1 ? 6 : 12);
    in.inst.dest_preg = g.R(128); in.inst.dest_en = g.R(2); in.inst.rob_idx = g.R(128);
    if (!in.en) {   // stale garbage in the slot: all the fields the spec records
      in.inst.func7 = g.R(128); in.inst.func3 = g.R(8); in.inst.imm = g.r32(); in.inst.src1_rdata = g.r32();
      in.inst.src2_rdata = g.r32(); in.inst.br_mask = g.rng(); in.inst.dest_preg = g.R(128); in.inst.dest_en = g.R(2);
      in.inst.rob_idx = g.R(128);
    }
    in.flush = g.P(p_flush[prof]);
    if (in.flush) in.flush_mask = g.P(250) ? ~0ull : sparse_mask(1 + g.R(3), prof == 1 ? 6 : 12);
    else if (g.P(100)) in.flush_mask = sparse_mask(2, 8);   // flush_mask is only meaningful with flush; keep it noisy
    if (g.P(p_clear[prof])) in.clear_mask = sparse_mask(1 + g.R(3), prof == 1 ? 6 : 12);
    if (!in.flush && !in.clear_mask && g.P(50)) in.clear_mask = ~0ull;

    fu.comb_begin();
    fu.comb_ctrl();
    fu.comb_issue();
    in.consume = fu.out.complete && g.P(p_consume[prof]);
    fu.comb_consume();

    S("in_en", in.en); S("in_consume", in.consume); S("in_flush", in.flush);
    S("in_flush_mask", in.flush_mask); S("in_clear_mask", in.clear_mask);
    S("in_inst_func3", in.inst.func3); S("in_inst_func7", in.inst.func7);
    S("in_inst_imm_rs2_bit0", in.inst.imm & 1);
    S("in_inst_src1_rdata", in.inst.src1_rdata); S("in_inst_src2_rdata", in.inst.src2_rdata);
    S("in_inst_br_mask", in.inst.br_mask); S("in_inst_dest_preg", in.inst.dest_preg);
    S("in_inst_dest_en", in.inst.dest_en); S("in_inst_rob_idx", in.inst.rob_idx);
    S("out_ready", fu.out.ready); S("out_complete", fu.out.complete);
    if (fu.out.complete) {   // the don't-care outputs stay 0 in the trace; the spec compares them only when complete
      S("out_inst_result", fu.out.inst.result); S("out_inst_br_mask", fu.out.inst.br_mask);
      S("out_inst_dest_preg", fu.out.inst.dest_preg); S("out_inst_dest_en", fu.out.inst.dest_en);
      S("out_inst_rob_idx", fu.out.inst.rob_idx);
      n_comp++; if (in.consume) n_cons++;
    }
    w.commit(cyc + 3);
    fu.seq();
    sim_time++;
  }
  std::printf("%s: %ld cycles, completes %ld (consumed %ld)\n", out, ncyc, n_comp, n_cons);
  return 0;
}
