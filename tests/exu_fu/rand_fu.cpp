// Constrained-random trace generator for the exu_fu leaf modules (alu_bank, bru_bank, agu_bank, sdu_bank, csr_fu,
// mul_bank, div_bank).  It drives the *reference* FU classes of back-end/Exu/include/Fu.h through the AbstractFU
// interface (comb_begin / comb_ctrl / comb_issue / comb_consume / seq) and records the FU boundary in the same
// format as scripts/record.sh.  The C++ class is the golden model: every output in the trace is what the reference
// produced.  Select the unit with -DFU_ALU / -DFU_BRU / -DFU_AGU / -DFU_SDU / -DFU_CSR / -DFU_MUL / -DFU_DIV and pass
// -DFIELDS_HDR='"<mod>_fields.h"'.  Build: tests/exu_fu/run_rand.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include "Fu.h"
#include FIELDS_HDR
using namespace ttg_io;

long long sim_time = 0;  // global time of the reference (FixedLatencyFU / IterativeFU compare done_cycle with it)

static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }
static std::mt19937_64 rng;
static int R(int n) { return (int)(rng() % n); }
static bool P(int pct) { return R(100) < pct; }

// operand values: half corner cases (0, 1, -1, INT_MIN/MAX, shift amounts, byte/half boundaries), half random
static uint32_t V() {
  static const uint32_t c[] = {0, 1, 2, 3, 4, 7, 8, 15, 16, 24, 31, 32, 33, 0xffu, 0x100u, 0xffffu, 0x10000u, 0x7fffffffu,
                               0x80000000u, 0x80000001u, 0xffffffffu, 0xfffffffeu, 0xffff0000u, 0x0000ffffu, 0xff00ff00u,
                               0x00ff00ffu, 0x55555555u, 0xaaaaaaaau};
  if (P(50)) return c[R(sizeof(c) / sizeof(c[0]))];
  if (P(20)) return (uint32_t)rng() >> R(32);   // small / sparse magnitudes
  return (uint32_t)rng();
}
static uint64_t sparse_mask(int pool) {  // a few set bits drawn from the lowest `pool` branch tags
  uint64_t m = 0;
  for (int i = R(3); i > 0; i--) m |= 1ull << R(pool);
  return m;
}

#if defined(FU_ALU) || defined(FU_BRU) || defined(FU_AGU) || defined(FU_SDU) || defined(FU_CSR)
#if defined(FU_ALU)
#define NU 6
#elif defined(FU_BRU)
#define NU 4
#elif defined(FU_AGU)
#define NU 8
#elif defined(FU_SDU)
#define NU 4
#else
#define NU 1
#endif

static AbstractFU *make(int k) {
#if defined(FU_ALU)
  return new AluUnit("ALU", k);
#elif defined(FU_BRU)
  return new BruUnit("BRU", k);
#elif defined(FU_AGU)
  return new AguUnit("AGU", k);
#elif defined(FU_SDU)
  return new SduUnit("SDU", k);
#else
  return new CsrUnit("CSR", k);
#endif
}

// func7 values with their own meaning in the ALU, plus noise
static int F7() {
  static const int f[] = {0x00, 0x20, 0x10, 0x05, 0x04, 0x30, 0x24, 0x14, 0x34};
  return P(85) ? f[R(9)] : R(128);
}
// immediates whose low 5 bits hit the Zbb unary sub-opcodes / rev8 / orc.b shamts
static uint32_t IMM() {
  static const int lo[] = {0, 1, 2, 3, 4, 5, 6, 7, 24, 31};
  if (P(50)) return (P(50) ? 0x600u : (P(50) ? 0x698u : (P(50) ? 0x287u : 0x400u))) | lo[R(10)] | (P(20) ? V() << 12 : 0);
  return V();
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  rng.seed(argc > 2 ? strtoull(argv[2], 0, 0) : 1);
  int ncyc = argc > 3 ? atoi(argv[3]) : 60000;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  AbstractFU *fu[NU];
  for (int k = 0; k < NU; k++) fu[k] = make(k);
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);
  for (int c = 0; c < ncyc; c++) {
    for (int k = 0; k < NU; k++) {
      AbstractFU &u = *fu[k];
      u.in = AbstractFU::FuInput();
      ExuInst &i = u.in.inst;
      u.in.en = P(75);
      u.in.consume = P(50);
#if defined(FU_ALU)
      // the ALU port only sees these uop types (OP_MASK_ALU); UOP_JUMP never reaches it
      static const UopType ops[] = {UOP_FENCE, UOP_ECALL, UOP_EBREAK, UOP_SFENCE_VMA, UOP_FENCE_I, UOP_MRET, UOP_SRET};
      i.op = P(90) ? UOP_ADD : (P(30) ? UOP_WFI : ops[R(7)]);
      i.func3 = R(8); i.func7 = F7(); i.src1_is_pc = P(15); i.src2_is_imm = P(45);
      i.pc = V() & ~3u; i.imm = IMM(); i.src1_rdata = V(); i.src2_rdata = P(8) ? i.src1_rdata : V();
      if (P(8)) i.imm = i.src2_rdata;
#elif defined(FU_BRU)
      i.op = P(65) ? UOP_BR : UOP_JUMP;
      i.func3 = P(90) ? "\0\1\4\5\6\7"[R(6)] : R(8);   // func3 = 2/3 are not branch encodings but the C++ defines them
      i.src1_en = P(50); i.src1_rdata = V(); i.src2_rdata = P(30) ? i.src1_rdata : (P(10) ? i.src1_rdata + 1 : V());
      i.pc = V() & ~1u; i.imm = P(50) ? (V() & 0x1ffe) : V();
      i.ftq_pred_taken = P(50);
      uint32_t t_rel = i.pc + i.imm, t_ind = (i.src1_rdata + i.imm) & ~1u;
      i.ftq_next_pc = P(35) ? t_rel : (P(35) ? t_ind : (P(30) ? (uint32_t)rng() : t_rel ^ 1u));
#elif defined(FU_AGU)
      i.src1_rdata = V(); i.imm = V();
#elif defined(FU_SDU)
      i.is_atomic = P(60); i.func7 = (R(32) << 2) | R(4);  // amo_op = func7[6:2]
      i.src1_rdata = V(); i.src2_rdata = P(10) ? i.src1_rdata : V();
#endif
      i.result = 0;   // ExuInst built from a PrfExeUop starts with result = 0 (Exu.cpp comb_pipeline)
      u.comb_begin(); u.comb_ctrl(); u.comb_issue(); u.comb_consume();
      S("en", k, u.in.en); S("consume", k, u.in.consume);
#if defined(FU_ALU)
      S("op", k, i.op); S("func3", k, i.func3); S("func7", k, i.func7); S("src1_is_pc", k, i.src1_is_pc);
      S("src2_is_imm", k, i.src2_is_imm); S("pc", k, i.pc); S("imm", k, i.imm);
      S("src1_rdata", k, i.src1_rdata); S("src2_rdata", k, i.src2_rdata);
#elif defined(FU_BRU)
      S("op", k, i.op); S("func3", k, i.func3); S("src1_en", k, i.src1_en); S("src1_rdata", k, i.src1_rdata);
      S("src2_rdata", k, i.src2_rdata); S("pc", k, i.pc); S("imm", k, i.imm); S("ftq_pred_taken", k, i.ftq_pred_taken);
      S("ftq_next_pc", k, i.ftq_next_pc);
      S("br_taken", k, u.out.inst.br_taken); S("mispred", k, u.out.inst.mispred); S("diag_val", k, u.out.inst.diag_val);
#elif defined(FU_AGU)
      S("src1_rdata", k, i.src1_rdata); S("imm", k, i.imm);
#elif defined(FU_SDU)
      S("is_atomic", k, i.is_atomic); S("amo_op", k, i.func7 >> 2); S("src1_rdata", k, i.src1_rdata);
      S("src2_rdata", k, i.src2_rdata);
#endif
      S("complete", k, u.out.complete); S("ready", k, u.out.ready);
#if defined(FU_ALU) || defined(FU_AGU) || defined(FU_SDU)
      S("result", k, u.out.inst.result);
#endif
#ifdef FU_CSR
      if (u.out.complete && u.out.inst.result != 0) { fprintf(stderr, "csr result != 0\n"); return 1; }
#endif
#ifdef FU_BRU
      if (u.out.complete && u.out.inst.result != 0) { fprintf(stderr, "bru result != 0\n"); return 1; }
#endif
      u.seq();
    }
    sim_time++;
    w.commit(c + 1, 0);
  }
  w.flush();
  return 0;
}

#else  // FU_MUL / FU_DIV: stateful multi-cycle units
#if defined(FU_MUL)
#define NU 2
#else
#define NU 2
#endif

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  rng.seed(argc > 2 ? strtoull(argv[2], 0, 0) : 1);
  int ncyc = argc > 3 ? atoi(argv[3]) : 60000;
  int p_en = argc > 4 ? atoi(argv[4]) : 60;        // % of cycles with en
  int p_consume = argc > 5 ? atoi(argv[5]) : 40;   // % of cycles with consume
  int p_flush = argc > 6 ? atoi(argv[6]) : 4;      // % of cycles with a flush
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  AbstractFU *fu[NU];
  for (int k = 0; k < NU; k++) {
#if defined(FU_MUL)
    fu[k] = new MulUnit("MUL", k, MUL_MAX_LATENCY);
#else
    fu[k] = new DivUnit("DIV", k, DIV_MAX_LATENCY);
#endif
  }
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);
  for (int c = 0; c < ncyc; c++) {
    for (int k = 0; k < NU; k++) {
      AbstractFU &u = *fu[k];
      u.in = AbstractFU::FuInput();
      ExuInst &i = u.in.inst;
      u.in.en = P(p_en);
      u.in.consume = P(p_consume);
      // flush_mask is 0 unless flush (Exu::comb_fu_ctrl); 1% of cycles break that on purpose: the FU must ignore the mask
      u.in.flush = P(p_flush);
      if (u.in.flush) u.in.flush_mask = P(25) ? ~wire<BR_MASK_WIDTH>(0) : (wire<BR_MASK_WIDTH>)sparse_mask(P(70) ? 6 : 64);
      else if (P(1)) u.in.flush_mask = sparse_mask(6);
      u.in.clear_mask = P(20) ? sparse_mask(P(70) ? 6 : 64) : 0;
#if defined(FU_MUL)
      i.func3 = R(4);
#else
      i.func3 = 4 + R(4);
#endif
      i.src1_rdata = V(); i.src2_rdata = P(10) ? i.src1_rdata : V();
#if defined(FU_DIV)
      if (P(8)) i.src2_rdata = 0xffffffffu;
      if (P(5)) i.src1_rdata = 0x80000000u;
      if (P(6)) i.src2_rdata = 0;
#endif
      i.rob_idx = R(128); i.dest_preg = R(128); i.dest_en = R(2);
      i.br_mask = P(70) ? sparse_mask(6) : (P(50) ? rng() : sparse_mask(64));
      i.result = 0;
      u.comb_begin(); u.comb_ctrl(); u.comb_issue(); u.comb_consume();
      S("en", k, u.in.en); S("consume", k, u.in.consume); S("flush", k, u.in.flush);
      S("flush_mask", k, u.in.flush_mask); S("clear_mask", k, u.in.clear_mask);
      S("func3", k, i.func3 & 3); S("src1_rdata", k, i.src1_rdata); S("src2_rdata", k, i.src2_rdata);
      S("rob_idx", k, i.rob_idx); S("dest_preg", k, i.dest_preg); S("dest_en", k, i.dest_en); S("br_mask", k, i.br_mask);
      S("complete", k, u.out.complete); S("ready", k, u.out.ready);
      S("result", k, u.out.inst.result);
      S("done_rob_idx", k, u.out.inst.rob_idx); S("done_dest_preg", k, u.out.inst.dest_preg);
      S("done_dest_en", k, u.out.inst.dest_en); S("done_br_mask", k, u.out.inst.br_mask);
      u.seq();
    }
    sim_time++;
    w.commit(c + 1, 0);
  }
  w.flush();
  return 0;
}
#endif
