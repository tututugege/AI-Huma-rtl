// Operand / instruction generator shared by the differential compute test and the trace generator.
#pragma once
#include <cstdint>
#include <random>

struct FpGen {
  std::mt19937_64 rng;
  explicit FpGen(uint64_t seed) : rng(seed) {}
  uint32_t R(uint32_t n) { return (uint32_t)(rng() % n); }
  bool P(int permille) { return R(1000) < (uint32_t)permille; }
  uint32_t r32() { return (uint32_t)rng(); }

  // A "interesting" binary32 pattern.
  uint32_t f32() {
    uint32_t sign = (uint32_t)(rng() & 1) << 31;
    switch (R(16)) {
      case 0: return sign;                                        // +-0
      case 1: return sign | (r32() & 0x007FFFFF);                 // subnormal (or zero)
      case 2: return sign | (1u + R(64));                         // tiny subnormal
      case 3: return sign | 0x7F800000;                           // inf
      case 4: return sign | 0x7FC00000 | (R(4) ? 0 : (r32() & 0x003FFFFF));   // qNaN
      case 5: return sign | 0x7F800000 | (1 + (r32() & 0x003FFFFF));          // sNaN (payload != 0, quiet bit 0)
      case 6: return sign | 0x7F7FFFFF - R(4);                    // near max
      case 7: return sign | 0x00800000 + R(4);                    // near min normal
      case 8: return sign | ((uint32_t)(127 + (int)R(9) - 4) << 23) | (R(3) ? 0 : (r32() & 0x7FFFFF));  // around 1
      case 9: return sign | ((uint32_t)(1 + R(254)) << 23) | (r32() & 0x7FFFFF);                         // any normal
      case 10: return sign | ((uint32_t)(1 + R(254)) << 23);                                             // power of two
      case 11: return sign | ((uint32_t)(100 + R(60)) << 23) | (r32() & 0x7FFFFF);                       // moderate range
      case 12: return sign | ((uint32_t)(1 + R(254)) << 23) | (R(2) ? 0x7FFFFF : 1u);                    // mantissa edges
      case 13: return sign | ((uint32_t)(120 + R(40)) << 23) | ((r32() & 0x7FFFFF) & (0xFFFFFFFFu << R(24)));  // few bits
      default: return r32();
    }
  }
  // Second operand related to the first (cancellation, equal exponents, same value...).
  uint32_t f32_related(uint32_t a) {
    switch (R(8)) {
      case 0: return a;
      case 1: return a ^ 0x80000000;
      case 2: { int e = (int)((a >> 23) & 0xFF) + (int)R(5) - 2; if (e < 0) e = 0; if (e > 255) e = 255;
                return (r32() & 0x80000000) | ((uint32_t)e << 23) | (r32() & 0x7FFFFF); }
      case 3: return a + (R(5) - 2);                                  // 1 ulp neighbours
      case 4: return (a & 0xFF800000) | (r32() & 0x7FFFFF);           // same sign/exponent
      default: return f32();
    }
  }
  // 32-bit integer for fcvt.s.w / fcvt.s.wu
  uint32_t i32() {
    switch (R(10)) {
      case 0: return 0;
      case 1: return 0x80000000;
      case 2: return 0x7FFFFFFF;
      case 3: return 0xFFFFFFFF;
      case 4: return 1u << R(32);
      case 5: return (1u << R(32)) + (R(5) - 2);
      case 6: return r32() >> R(32);                                  // varying bit length
      case 7: return (uint32_t)(-(int32_t)(r32() >> R(32)));
      case 8: { uint32_t v = r32() | 0x80000000u; return v >> R(8) << R(8); }   // many trailing zeros, ties/sticky
      default: return r32();
    }
  }
  // Float input for fcvt.w.s: concentrates on the exponent range where the integer part is 0..2^32 and on exact ties.
  uint32_t f32_for_int() {
    uint32_t sign = (uint32_t)(rng() & 1) << 31;
    switch (R(6)) {
      case 0: return sign | ((uint32_t)(120 + R(20)) << 23) | (r32() & 0x7FFFFF);       // |x| < 1 .. 2^12
      case 1: return sign | ((uint32_t)(140 + R(25)) << 23) | (r32() & 0x7FFFFF);       // up to overflow
      case 2: { uint32_t k = R(33); double v = (double)(r32() >> R(32)) + (R(2) ? 0.5 : 0.0); (void)k;
                float f = (float)v; uint32_t u; __builtin_memcpy(&u, &f, 4); return sign | (u & 0x7FFFFFFF); }
      case 3: { float f = (float)((double)(int32_t)(r32() >> R(32)) / (double)(1u << R(3))); uint32_t u; __builtin_memcpy(&u, &f, 4); return u; }
      default: return f32();
    }
  }
  // func3 rounding field: legal modes mostly, 7 (DYN, softfloat: RNE) sometimes, reserved 5 (softfloat: RTZ) rarely.
  // Reserved 6 is excluded: the linked softfloat build treats it as round-to-odd, which the RTL does not implement
  // (no decoded RISC-V instruction has rm=6; see docs/modules/fpu.md section 4).
  uint32_t rm_any() {
    uint32_t v = R(100);
    if (v < 80) return v % 5;
    if (v < 95) return 7;
    return 5;
  }
};

// instruction classes of the FPU: {func7, func3 (or -1 = rounding mode), imm}
struct FpInstr { uint32_t func7, func3, imm; int cls; };
enum { C_ADD, C_SUB, C_MUL, C_DIV, C_SQRT, C_CVT_W, C_CVT_WU, C_CVT_SW, C_CVT_SWU, C_SGNJ, C_SGNJN, C_SGNJX, C_MIN, C_MAX,
       C_EQ, C_LT, C_LE, C_CLASS, C_NUM };
