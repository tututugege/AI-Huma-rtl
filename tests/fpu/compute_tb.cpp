// Differential test: fpu decode+compute (Verilated fpu_exec_tb) against the reference FPUSoftfloat on random/corner vectors.
//   usage: compute_tb [vectors per instruction class (default 2000000)] [seed]
#include <cstdio>
#include <cstdlib>
#include "golden.h"
#include "fpgen.h"
#include "Vfpu_exec_tb.h"
long long sim_time = 0;
static const FpInstr kInstr[C_NUM] = {
  {0x00, 0, 0, C_ADD}, {0x04, 0, 0, C_SUB}, {0x08, 0, 0, C_MUL}, {0x0C, 0, 0, C_DIV}, {0x2C, 0, 0, C_SQRT},
  {0x60, 0, 0, C_CVT_W}, {0x60, 0, 1, C_CVT_WU}, {0x68, 0, 0, C_CVT_SW}, {0x68, 0, 1, C_CVT_SWU},
  {0x10, 0, 0, C_SGNJ}, {0x10, 1, 0, C_SGNJN}, {0x10, 2, 0, C_SGNJX}, {0x14, 0, 0, C_MIN}, {0x14, 1, 0, C_MAX},
  {0x50, 2, 0, C_EQ}, {0x50, 1, 0, C_LT}, {0x50, 0, 0, C_LE}, {0x70, 1, 0, C_CLASS}};
static const char *kName[C_NUM] = {"fadd", "fsub", "fmul", "fdiv", "fsqrt", "fcvt.w.s", "fcvt.wu.s", "fcvt.s.w", "fcvt.s.wu",
  "fsgnj", "fsgnjn", "fsgnjx", "fmin", "fmax", "feq", "flt", "fle", "fclass"};
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 2000000;
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  FpGen g(seed);
  FpuGolden gold;
  Vfpu_exec_tb dut;
  long total_bad = 0;
  for (int c = 0; c < C_NUM; c++) {
    long bad = 0, h[5] = {};   // result classes: zero, subnormal, normal, inf, nan (float-result kinds only)
    for (long i = 0; i < n; i++) {
      FpInstr in = kInstr[c];
      uint32_t a = g.f32(), b = g.P(500) ? g.f32_related(a) : g.f32();
      uint32_t rm = g.rm_any();
      bool arith = c <= C_SQRT || c == C_CVT_W || c == C_CVT_WU || c == C_CVT_SW || c == C_CVT_SWU;
      if (arith) in.func3 = rm;
      if (c == C_CVT_W || c == C_CVT_WU) a = g.f32_for_int();
      if (c == C_CVT_SW || c == C_CVT_SWU) a = g.i32();
      int lat;
      uint32_t ref = gold.run(in.func7, in.func3, in.imm, a, b, &lat);
      dut.func7 = in.func7; dut.func3 = in.func3; dut.rs2_bit0 = in.imm & 1; dut.a = a; dut.b = b; dut.eval();
      { uint32_t e = (ref >> 23) & 0xFF, fr = ref & 0x7FFFFF;
        h[e == 0 ? (fr ? 1 : 0) : e == 255 ? (fr ? 4 : 3) : 2]++; }
      if (dut.result != ref || dut.latency_minus_1 != lat - 1) {
        if (bad++ < 5)
          std::printf("MISMATCH %s rm=%u a=%08x b=%08x ref=%08x lat=%d rtl=%08x lat=%d\n", kName[c], in.func3, a, b, ref, lat,
                      (unsigned)dut.result, dut.latency_minus_1 + 1);
      }
    }
    std::printf("%-10s %ld vectors, %ld mismatches   (results: zero %ld sub %ld norm %ld inf %ld nan %ld)\n", kName[c], n, bad,
                h[0], h[1], h[2], h[3], h[4]);
    total_bad += bad;
  }
  std::printf("%s\n", total_bad ? "FAIL" : "PASS");
  return total_bad != 0;
}
