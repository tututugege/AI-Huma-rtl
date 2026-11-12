// F/D arithmetic of the RTL's FP units for simulation (DPI-C): Berkeley softfloat, same semantics as Ref_cpu::RVFD() of the
// function model (the per-commit reference).  The instruction fields come from the uop: op5 = inst[6:2], f3 = rm / funct3,
// f7rs2 = inst[31:20] (funct7 | rs2), operands a / b / c = FP registers rs1 / rs2 / rs3, xi = integer rs1.
// Replaced by a synthesizable datapath in S7.  Reserved encodings and reserved rounding modes (the illegal-instruction
// traps, S5) return 0 with no flags.
#include <cstdint>
#include <cstdlib>

extern "C" {
#include "softfloat.h"
}

namespace {
constexpr uint32_t kCanonNaN32 = 0x7fc00000u;
constexpr uint64_t kCanonNaN64 = 0x7ff8000000000000ull;
constexpr uint32_t S32 = 0x80000000u;
constexpr uint64_t S64 = 0x8000000000000000ull;

inline uint64_t nanbox32(uint32_t v) { return 0xFFFFFFFF00000000ull | v; }
inline uint32_t unbox32(uint64_t v) { return (v >> 32) == 0xFFFFFFFFu ? static_cast<uint32_t>(v) : kCanonNaN32; }
inline float32_t to_f32(uint32_t v) { float32_t f; f.v = v; return f; }
inline float64_t to_f64(uint64_t v) { float64_t f; f.v = v; return f; }

inline bool is_nan32(uint32_t v) { return ((v & 0x7F800000u) == 0x7F800000u) && ((v & 0x007FFFFFu) != 0); }
inline bool is_snan32(uint32_t v) { return is_nan32(v) && (((v >> 22) & 1u) == 0); }
inline bool is_nan64(uint64_t v) { return ((v >> 52) & 0x7FFu) == 0x7FFu && (v & 0x000FFFFFFFFFFFFFull) != 0; }
inline bool is_snan64(uint64_t v) { return is_nan64(v) && ((v >> 51) & 1u) == 0; }

template <typename UInt, int EXPW, int MANTW>
uint32_t fclass_generic(UInt bits) {
  const UInt sign = (bits >> (EXPW + MANTW)) & 1u;
  const UInt exp = (bits >> MANTW) & ((UInt(1) << EXPW) - 1);
  const UInt mant = bits & ((UInt(1) << MANTW) - 1);
  const bool expmax = exp == ((UInt(1) << EXPW) - 1);
  const bool zero = exp == 0 && mant == 0, sub = exp == 0 && mant != 0, inf = expmax && mant == 0, nan = expmax && mant != 0;
  if (nan) return ((mant >> (MANTW - 1)) & 1u) ? (1u << 9) : (1u << 8);
  if (inf) return sign ? (1u << 0) : (1u << 7);
  if (zero) return sign ? (1u << 3) : (1u << 4);
  if (sub) return sign ? (1u << 2) : (1u << 5);
  return sign ? (1u << 1) : (1u << 6);
}

uint32_t f32_min_riscv(uint32_t a, uint32_t b) {
  if (is_snan32(a) || is_snan32(b)) softfloat_exceptionFlags |= softfloat_flag_invalid;
  const bool an = is_nan32(a), bn = is_nan32(b);
  if (an && bn) return kCanonNaN32;
  if (an) return b;
  if (bn) return a;
  if (f32_lt(to_f32(a), to_f32(b))) return a;
  if (f32_lt(to_f32(b), to_f32(a))) return b;
  return a | b;   // -0.0 wins on ties
}
uint32_t f32_max_riscv(uint32_t a, uint32_t b) {
  if (is_snan32(a) || is_snan32(b)) softfloat_exceptionFlags |= softfloat_flag_invalid;
  const bool an = is_nan32(a), bn = is_nan32(b);
  if (an && bn) return kCanonNaN32;
  if (an) return b;
  if (bn) return a;
  if (f32_lt(to_f32(a), to_f32(b))) return b;
  if (f32_lt(to_f32(b), to_f32(a))) return a;
  return a & b;   // +0.0 wins on ties
}
uint64_t f64_min_riscv(uint64_t a, uint64_t b) {
  if (is_snan64(a) || is_snan64(b)) softfloat_exceptionFlags |= softfloat_flag_invalid;
  const bool an = is_nan64(a), bn = is_nan64(b);
  if (an && bn) return kCanonNaN64;
  if (an) return b;
  if (bn) return a;
  if (f64_lt(to_f64(a), to_f64(b))) return a;
  if (f64_lt(to_f64(b), to_f64(a))) return b;
  return a | b;
}
uint64_t f64_max_riscv(uint64_t a, uint64_t b) {
  if (is_snan64(a) || is_snan64(b)) softfloat_exceptionFlags |= softfloat_flag_invalid;
  const bool an = is_nan64(a), bn = is_nan64(b);
  if (an && bn) return kCanonNaN64;
  if (an) return b;
  if (bn) return a;
  if (f64_lt(to_f64(a), to_f64(b))) return b;
  if (f64_lt(to_f64(b), to_f64(a))) return a;
  return a & b;
}

struct Out { uint64_t res = 0; uint32_t flags = 0; };

Out compute(uint32_t op5, uint32_t funct3, uint32_t f7rs2, uint64_t a64, uint64_t b64, uint64_t c64, uint64_t xi,
            uint32_t frm, uint32_t xlen) {
  Out o;
  const uint32_t opcode = (op5 << 2) | 3u;
  const uint32_t funct7 = (f7rs2 >> 5) & 0x7Fu, rs2 = f7rs2 & 0x1Fu, fmt = funct7 & 3u, funct5 = funct7 >> 2;
  if (fmt > 1) return o;
  const bool D = fmt == 1;
  auto set_rm = [&]() -> bool {
    const uint32_t rm = funct3 == 7 ? (frm & 7u) : funct3;
    switch (rm) {
    case 0: softfloat_roundingMode = softfloat_round_near_even; return true;
    case 1: softfloat_roundingMode = softfloat_round_minMag; return true;
    case 2: softfloat_roundingMode = softfloat_round_min; return true;
    case 3: softfloat_roundingMode = softfloat_round_max; return true;
    case 4: softfloat_roundingMode = softfloat_round_near_maxMag; return true;
    default: return false;
    }
  };
  softfloat_exceptionFlags = 0;
  const uint32_t a32 = unbox32(a64), b32 = unbox32(b64), c32 = unbox32(c64);
  auto done = [&]() { o.flags = softfloat_exceptionFlags & 0x1Fu; return o; };
  auto bad = [&]() { Out z; return z; };
  auto wrfS = [&](uint32_t v) { o.res = nanbox32(v); };
  auto wrfD = [&](uint64_t v) { o.res = v; };
  auto wrx = [&](uint64_t v) { o.res = xlen == 64 ? v : (v & 0xFFFFFFFFull); };

  if (op5 != 0x14) {   // fmadd / fmsub / fnmsub / fnmadd
    if (!set_rm()) return bad();
    const bool neg_a = (op5 == 0x12 || op5 == 0x13), neg_c = (op5 == 0x11 || op5 == 0x13);
    if (D) {
      uint64_t x = a64, z = c64;
      if (neg_a) x ^= S64;
      if (neg_c) z ^= S64;
      wrfD(f64_mulAdd(to_f64(x), to_f64(b64), to_f64(z)).v);
    } else {
      uint32_t x = a32, z = c32;
      if (neg_a) x ^= S32;
      if (neg_c) z ^= S32;
      wrfS(f32_mulAdd(to_f32(x), to_f32(b32), to_f32(z)).v);
    }
    (void)opcode;
    return done();
  }
  switch (funct5) {
  case 0x00: case 0x01: case 0x02: case 0x03:
    if (!set_rm()) return bad();
    if (D) {
      const float64_t x = to_f64(a64), y = to_f64(b64);
      wrfD((funct5 == 0 ? f64_add(x, y) : funct5 == 1 ? f64_sub(x, y) : funct5 == 2 ? f64_mul(x, y) : f64_div(x, y)).v);
    } else {
      const float32_t x = to_f32(a32), y = to_f32(b32);
      wrfS((funct5 == 0 ? f32_add(x, y) : funct5 == 1 ? f32_sub(x, y) : funct5 == 2 ? f32_mul(x, y) : f32_div(x, y)).v);
    }
    break;
  case 0x0B:
    if (rs2 != 0 || !set_rm()) return bad();
    if (D) wrfD(f64_sqrt(to_f64(a64)).v); else wrfS(f32_sqrt(to_f32(a32)).v);
    break;
  case 0x04:
    if (funct3 > 2) return bad();
    if (D) {
      const uint64_t sgn = funct3 == 0 ? (b64 & S64) : funct3 == 1 ? (~b64 & S64) : ((a64 ^ b64) & S64);
      wrfD((a64 & ~S64) | sgn);
    } else {
      const uint32_t sgn = funct3 == 0 ? (b32 & S32) : funct3 == 1 ? (~b32 & S32) : ((a32 ^ b32) & S32);
      wrfS((a32 & ~S32) | sgn);
    }
    break;
  case 0x05:
    if (funct3 > 1) return bad();
    if (D) wrfD(funct3 == 0 ? f64_min_riscv(a64, b64) : f64_max_riscv(a64, b64));
    else wrfS(funct3 == 0 ? f32_min_riscv(a32, b32) : f32_max_riscv(a32, b32));
    break;
  case 0x08:
    if (D) {
      if (rs2 != 0 || !set_rm()) return bad();
      wrfD(f32_to_f64(to_f32(a32)).v);
    } else {
      if (rs2 != 1 || !set_rm()) return bad();
      wrfS(f64_to_f32(to_f64(a64)).v);
    }
    break;
  case 0x14: {
    if (funct3 > 2) return bad();
    bool r;
    if (D) r = funct3 == 2 ? f64_eq(to_f64(a64), to_f64(b64)) : funct3 == 1 ? f64_lt(to_f64(a64), to_f64(b64)) : f64_le(to_f64(a64), to_f64(b64));
    else r = funct3 == 2 ? f32_eq(to_f32(a32), to_f32(b32)) : funct3 == 1 ? f32_lt(to_f32(a32), to_f32(b32)) : f32_le(to_f32(a32), to_f32(b32));
    wrx(r ? 1 : 0);
    break;
  }
  case 0x18: {
    if (rs2 > (xlen == 64 ? 3u : 1u) || !set_rm()) return bad();
    const uint_fast8_t rm = softfloat_roundingMode;
    uint64_t r;
    if (D) {
      const float64_t x = to_f64(a64);
      r = rs2 == 0 ? static_cast<uint64_t>(static_cast<int64_t>(f64_to_i32(x, rm, true)))
        : rs2 == 1 ? static_cast<uint64_t>(static_cast<int64_t>(static_cast<int32_t>(f64_to_ui32(x, rm, true))))
        : rs2 == 2 ? static_cast<uint64_t>(f64_to_i64(x, rm, true)) : static_cast<uint64_t>(f64_to_ui64(x, rm, true));
    } else {
      const float32_t x = to_f32(a32);
      r = rs2 == 0 ? static_cast<uint64_t>(static_cast<int64_t>(f32_to_i32(x, rm, true)))
        : rs2 == 1 ? static_cast<uint64_t>(static_cast<int64_t>(static_cast<int32_t>(f32_to_ui32(x, rm, true))))
        : rs2 == 2 ? static_cast<uint64_t>(f32_to_i64(x, rm, true)) : static_cast<uint64_t>(f32_to_ui64(x, rm, true));
    }
    wrx(r);
    break;
  }
  case 0x1A: {
    if (rs2 > (xlen == 64 ? 3u : 1u) || !set_rm()) return bad();
    const uint64_t x = xlen == 64 ? xi : (xi & 0xFFFFFFFFull);
    if (D) {
      wrfD((rs2 == 0 ? i32_to_f64(static_cast<int32_t>(x)) : rs2 == 1 ? ui32_to_f64(static_cast<uint32_t>(x))
            : rs2 == 2 ? i64_to_f64(static_cast<int64_t>(x)) : ui64_to_f64(x)).v);
    } else {
      wrfS((rs2 == 0 ? i32_to_f32(static_cast<int32_t>(x)) : rs2 == 1 ? ui32_to_f32(static_cast<uint32_t>(x))
            : rs2 == 2 ? i64_to_f32(static_cast<int64_t>(x)) : ui64_to_f32(x)).v);
    }
    break;
  }
  case 0x1C:
    if (rs2 != 0 || funct3 > 1 || (xlen == 32 && D && funct3 == 0)) return bad();
    if (funct3 == 0) wrx(D ? a64 : static_cast<uint64_t>(static_cast<int64_t>(static_cast<int32_t>(a64))));
    else wrx(D ? fclass_generic<uint64_t, 11, 52>(a64) : fclass_generic<uint32_t, 8, 23>(a32));
    break;
  case 0x1E:
    if (rs2 != 0 || funct3 != 0 || (xlen == 32 && D)) return bad();
    if (D) wrfD(xi); else wrfS(static_cast<uint32_t>(xi));
    break;
  default:
    return bad();
  }
  return done();
}
}  // namespace

extern "C" {
uint64_t fp_dpi_res(uint32_t op5, uint32_t f3, uint32_t f7rs2, uint64_t a, uint64_t b, uint64_t c, uint64_t xi, uint32_t frm,
                    uint32_t xlen) {
  return compute(op5, f3, f7rs2, a, b, c, xi, frm, xlen).res;
}
uint32_t fp_dpi_flags(uint32_t op5, uint32_t f3, uint32_t f7rs2, uint64_t a, uint64_t b, uint64_t c, uint64_t xi, uint32_t frm,
                      uint32_t xlen) {
  return compute(op5, f3, f7rs2, a, b, c, xi, frm, xlen).flags;
}
}
