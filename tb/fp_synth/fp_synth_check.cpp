#include "Vfp_synth_check_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" {
uint32_t fp_dpi_bad(uint32_t op5, uint32_t f3, uint32_t f7rs2, uint64_t a, uint64_t b, uint64_t c, uint64_t xi, uint32_t frm, uint32_t xlen);
uint64_t fp_dpi_res(uint32_t op5, uint32_t f3, uint32_t f7rs2, uint64_t a, uint64_t b, uint64_t c, uint64_t xi, uint32_t frm, uint32_t xlen);
uint32_t fp_dpi_flags(uint32_t op5, uint32_t f3, uint32_t f7rs2, uint64_t a, uint64_t b, uint64_t c, uint64_t xi, uint32_t frm, uint32_t xlen);
}

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static uint64_t nxt() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static uint64_t gen_fp64(bool is_d) {
  static const uint64_t c64[] = {
    0x0000000000000000ULL, 0x8000000000000000ULL, // +0, -0
    0x0000000000000001ULL, 0x8000000000000001ULL, // min subnormal
    0x000fffffffffffffULL, 0x800fffffffffffffULL, // max subnormal
    0x0010000000000000ULL, 0x8010000000000000ULL, // min normal
    0x36a0000000000000ULL, 0x3690000000000000ULL, // around float subnormal boundary (2^-149, 2^-150)
    0x380fffffe0000000ULL, 0x380ffffff0000000ULL, // float tininess-after-rounding boundary!
    0x3810000000000000ULL, 0x47efffffe0000000ULL, // float min normal, max finite
    0x47effffff0000000ULL, 0x47f0000000000000ULL, // float overflow boundary
    0x3fdfffffffffffffULL, 0x3fe0000000000000ULL, // <0.5, 0.5
    0x3fe0000000000001ULL, 0x3ff0000000000000ULL, // >0.5, 1.0
    0xbfe0000000000000ULL, 0xbff0000000000000ULL, // -0.5, -1.0
    0x41dfffffffc00000ULL, 0x41e0000000000000ULL, // INT32_MAX, 2^31
    0xc1e0000000000000ULL, 0xc1e0000000200000ULL, // -2^31, -2^31-1
    0x41efffffffe00000ULL, 0x41f0000000000000ULL, // UINT32_MAX, 2^32
    0x43dfffffffffffffULL, 0x43e0000000000000ULL, // ~2^63-1, 2^63
    0xc3e0000000000000ULL, 0xc3e0000000000001ULL, // -2^63, <-2^63
    0x43efffffffffffffULL, 0x43f0000000000000ULL, // ~2^64-1, 2^64
    0x7fefffffffffffffULL, 0xffefffffffffffffULL, // max finite
    0x7ff0000000000000ULL, 0xfff0000000000000ULL, // +inf, -inf
    0x7ff0000000000001ULL, 0xfff0000000000001ULL, // sNaN
    0x7ff8000000000000ULL, 0xfff8000000000001ULL  // qNaN
  };
  static const uint32_t c32[] = {
    0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u,
    0x007fffffu, 0x807fffffu, 0x00800000u, 0x80800000u,
    0x3effffffu, 0x3f000000u, 0x3f000001u, 0x3f800000u,
    0xbf000000u, 0xbf800000u, 0x4effffffu, 0x4f000000u,
    0xcf000000u, 0xcf000001u, 0x4f7fffffu, 0x4f800000u,
    0x5effffffu, 0x5f000000u, 0xdf000000u, 0xdf000001u,
    0x5f7fffffu, 0x5f800000u, 0x7f7fffffu, 0xff7fffffu,
    0x7f800000u, 0xff800000u, 0x7f800001u, 0xff800001u,
    0x7fc00000u, 0xffc00001u
  };
  uint64_t r = nxt();
  if (is_d) {
    if ((r & 3) == 0) return c64[(r >> 2) % (sizeof(c64) / sizeof(c64[0]))];
    if ((r & 7) == 1) { // bias near float range
      uint64_t e = (860 + ((r >> 8) % 300)) & 0x7ffULL;
      return ((r & 16) ? (1ULL << 63) : 0) | (e << 52) | (nxt() & ((1ULL << 52) - 1));
    }
    return nxt();
  } else {
    uint32_t v = ((r & 3) == 0) ? c32[(r >> 2) % (sizeof(c32) / sizeof(c32[0]))] : (uint32_t)nxt();
    // 10% unboxed NaN-boxing test
    return ((r & 15) == 15) ? (((uint64_t)(uint32_t)nxt() << 32) | v) : (0xffffffff00000000ULL | v);
  }
}

int main() {
  Vfp_synth_check_top top;
  uint64_t n_misc = 0, n_i2f = 0, n_fcvt = 0;

  auto check = [&](const char *name, uint32_t op5, uint32_t f3, uint32_t f7rs2,
                   uint64_t a, uint64_t b, uint64_t xi, uint32_t frm,
                   uint64_t got_r, uint32_t got_f, uint32_t got_bad) {
    uint32_t exp_bad = fp_dpi_bad(op5, f3, f7rs2, a, b, 0, xi, frm, 64);
    uint64_t exp_r   = exp_bad ? 0 : fp_dpi_res(op5, f3, f7rs2, a, b, 0, xi, frm, 64);
    uint32_t exp_f   = exp_bad ? 0 : fp_dpi_flags(op5, f3, f7rs2, a, b, 0, xi, frm, 64);
    if (got_bad != exp_bad || (!exp_bad && (got_r != exp_r || got_f != exp_f))) {
      std::fprintf(stderr, "FAIL %s f3=%u f7rs2=%03x a=%016llx b=%016llx xi=%016llx frm=%u | "
                           "exp=(r=%016llx f=%02x bad=%u) got=(r=%016llx f=%02x bad=%u)\n",
                   name, f3, f7rs2, (unsigned long long)a, (unsigned long long)b, (unsigned long long)xi, frm,
                   (unsigned long long)exp_r, exp_f, exp_bad,
                   (unsigned long long)got_r, got_f, got_bad);
      std::exit(1);
    }
  };

  // 1. FMISC: fsgnj(0x04), fmin/fmax(0x05), fcmp(0x14), fmv.x/fclass(0x1c)
  const uint32_t misc_f5[] = {0x04, 0x05, 0x14, 0x1c};
  for (int i = 0; i < 400000; i++) {
    uint32_t f5  = misc_f5[nxt() & 3];
    uint32_t fmt = nxt() & 1;
    uint32_t rs2 = (f5 == 0x1c) ? ((nxt() & 7) == 0 ? (nxt() & 31) : 0) : (nxt() & 31);
    uint32_t f3  = nxt() & 7;
    uint32_t f7rs2 = ((f5 << 2) | fmt) << 5 | rs2;
    uint64_t a = gen_fp64(fmt == 1), b = gen_fp64(fmt == 1);
    top.func3 = f3; top.imm = (0x14u << 12) | f7rs2; top.fsrc1 = a; top.fsrc2 = b; top.int_src = 0; top.frm = 0;
    top.eval();
    check("FMISC", 0x14, f3, f7rs2, a, b, 0, 0, top.misc_res, top.misc_flg, top.misc_bad);
    n_misc++;
  }

  // 2. I2F: fcvt.{s,d}.{w,wu,l,lu}(0x1a), fmv.{w,d}.x(0x1e)
  for (int i = 0; i < 300000; i++) {
    uint32_t f5  = (nxt() & 3) ? 0x1a : 0x1e;
    uint32_t fmt = nxt() & 1;
    uint32_t rs2 = (f5 == 0x1e) ? ((nxt() & 7) == 0 ? (nxt() & 31) : 0) : ((nxt() & 7) == 0 ? (nxt() & 31) : (nxt() & 3));
    uint32_t f3  = (f5 == 0x1e) ? ((nxt() & 7) == 0 ? (nxt() & 7) : 0) : (nxt() & 7);
    uint32_t frm = nxt() & 7;
    uint32_t f7rs2 = ((f5 << 2) | fmt) << 5 | rs2;
    uint64_t xi = nxt();
    if ((i & 7) == 0) xi = 0;
    else if ((i & 7) == 1) xi = (1ULL << 63);
    else if ((i & 7) == 2) xi = ~0ULL;
    else if ((i & 7) == 3) xi = (1ULL << 31);
    else if ((i & 7) == 4) xi = 0x7fffffffULL;
    top.func3 = f3; top.imm = (0x14u << 12) | f7rs2; top.int_src = xi; top.frm = frm; top.fsrc1 = 0; top.fsrc2 = 0;
    top.eval();
    check("I2F", 0x14, f3, f7rs2, 0, 0, xi, frm, top.i2f_res, top.i2f_flg, top.i2f_bad);
    n_i2f++;
  }

  // 3. FCVT: fcvt.s.d / fcvt.d.s (0x08), fcvt.{w,wu,l,lu}.{s,d} (0x18)
  for (int i = 0; i < 500000; i++) {
    uint32_t f5  = (nxt() & 1) ? 0x08 : 0x18;
    uint32_t fmt = nxt() & 1;
    uint32_t rs2 = (f5 == 0x08) ? ((nxt() & 7) == 0 ? (nxt() & 31) : (fmt == 1 ? 0 : 1))
                                : ((nxt() & 7) == 0 ? (nxt() & 31) : (nxt() & 3));
    uint32_t f3  = nxt() & 7;
    uint32_t frm = nxt() & 7;
    uint32_t f7rs2 = ((f5 << 2) | fmt) << 5 | rs2;
    bool src_is_d = (f5 == 0x08) ? (fmt == 0) : (fmt == 1);
    uint64_t a = gen_fp64(src_is_d);
    top.func3 = f3; top.imm = (0x14u << 12) | f7rs2; top.fsrc1 = a; top.fsrc2 = 0; top.int_src = 0; top.frm = frm;
    top.eval();
    check("FCVT", 0x14, f3, f7rs2, a, 0, 0, frm, top.fcvt_res, top.fcvt_flg, top.fcvt_bad);
    n_fcvt++;
  }

  // 4. FMA (4-stage pipelined): fmadd/fmsub/fnmsub/fnmadd (op5=0x10..0x13) + fadd/fsub/fmul (op5=0x14, f5=0..2)
  struct FmaExp { uint32_t op5, f3, f7rs2, frm; uint64_t a, b, c, r; uint32_t f, bad; bool v; };
  FmaExp pipe[3] = {};
  uint64_t n_fma = 0;
  for (int i = 0; i < 1000000; i++) {
    uint32_t kind = nxt() % 7;
    uint32_t op5, f5;
    if (kind < 4) { op5 = 0x10 + kind; f5 = 0; }
    else          { op5 = 0x14; f5 = kind - 4; }
    uint32_t fmt = nxt() & 1;
    uint32_t f3  = nxt() & 7;
    uint32_t frm = nxt() & 7;
    uint32_t f7rs2 = ((f5 << 2) | fmt) << 5;
    uint64_t a = gen_fp64(fmt == 1), b = gen_fp64(fmt == 1), c = gen_fp64(fmt == 1);
    // Bias 25% near-cancellation and near-subnormal exponents to stress sticky/LZA/tininess
    if ((i & 3) == 0 && fmt == 1) {
      uint64_t ea = (nxt() % 2046) + 1;
      uint64_t eb = (nxt() % 2046) + 1;
      int64_t  ec = (int64_t)ea + (int64_t)eb - 1023 + (int64_t)((nxt() % 130) - 65);
      if (ec < 0) ec = 0;
      if (ec > 2046) ec = 2046;
      a = ((nxt() & 1) << 63) | (ea << 52) | (nxt() & ((1ULL << 52) - 1));
      b = ((nxt() & 1) << 63) | (eb << 52) | (nxt() & ((1ULL << 52) - 1));
      c = ((nxt() & 1) << 63) | ((uint64_t)ec << 52) | (nxt() & ((1ULL << 52) - 1));
    }
    top.func3 = f3; top.imm = (op5 << 12) | f7rs2; top.fsrc1 = a; top.fsrc2 = b; top.fsrc3 = c; top.frm = frm;
    top.clk = 0; top.eval();
    if (pipe[2].v) {
      const auto &e = pipe[2];
      if (top.fma_bad != e.bad || (!e.bad && (top.fma_res != e.r || top.fma_flg != e.f))) {
        std::fprintf(stderr, "FAIL FMA op5=%02x f3=%u f7rs2=%03x frm=%u a=%016llx b=%016llx c=%016llx | "
                             "exp=(r=%016llx f=%02x bad=%u) got=(r=%016llx f=%02x bad=%u)\n",
                     e.op5, e.f3, e.f7rs2, e.frm, (unsigned long long)e.a, (unsigned long long)e.b, (unsigned long long)e.c,
                     (unsigned long long)e.r, e.f, e.bad,
                     (unsigned long long)top.fma_res, top.fma_flg, top.fma_bad);
        std::exit(1);
      }
      n_fma++;
    }
    FmaExp cur;
    cur.op5 = op5; cur.f3 = f3; cur.f7rs2 = f7rs2; cur.frm = frm; cur.a = a; cur.b = b; cur.c = c; cur.v = true;
    cur.bad = fp_dpi_bad(op5, f3, f7rs2, a, b, c, 0, frm, 64);
    cur.r   = cur.bad ? 0 : fp_dpi_res(op5, f3, f7rs2, a, b, c, 0, frm, 64);
    cur.f   = cur.bad ? 0 : fp_dpi_flags(op5, f3, f7rs2, a, b, c, 0, frm, 64);
    top.clk = 1; top.eval();
    pipe[2] = pipe[1];
    pipe[1] = pipe[0];
    pipe[0] = cur;
  }

  // 5. FDIV / FSQRT (iterative: fdiv.s=11, fsqrt.s=13, fdiv.d=19, fsqrt.d=23 cycles)
  top.rst_n = 0; top.div_accept = 0; top.div_run = 0;
  top.clk = 0; top.eval(); top.clk = 1; top.eval();
  top.rst_n = 1;
  uint64_t n_fdiv = 0;
  for (int i = 0; i < 150000; i++) {
    bool is_sq = (nxt() & 1) != 0;
    uint32_t f5 = is_sq ? 0x0b : 0x03;
    uint32_t fmt = nxt() & 1;
    uint32_t rs2 = is_sq ? ((nxt() & 15) == 0 ? (nxt() & 31) : 0) : (nxt() & 31);
    uint32_t f3  = nxt() & 7;
    uint32_t frm = nxt() & 7;
    uint32_t f7rs2 = ((f5 << 2) | fmt) << 5 | rs2;
    uint64_t a = gen_fp64(fmt == 1), b = gen_fp64(fmt == 1);
    const int lat = is_sq ? (fmt ? 23 : 13) : (fmt ? 19 : 11);
    top.func3 = f3; top.imm = (0x14u << 12) | f7rs2; top.fsrc1 = a; top.fsrc2 = b; top.frm = frm;
    top.div_accept = 1; top.div_run = 0;
    top.clk = 0; top.eval(); top.clk = 1; top.eval();
    top.div_accept = 0; top.div_run = 1;
    for (int c = 1; c < lat; c++) { top.clk = 0; top.eval(); top.clk = 1; top.eval(); }
    top.div_run = 0; top.eval();
    check(is_sq ? "FSQRT" : "FDIV", 0x14, f3, f7rs2, a, b, 0, frm, top.fdiv_res, top.fdiv_flg, top.fdiv_bad);
    n_fdiv++;
  }

  std::printf("fp_synth_check: PASS (FMISC=%llu, I2F=%llu, FCVT=%llu, FMA=%llu, FDIV/SQRT=%llu, total=%llu, 0 mismatches)\n",
              (unsigned long long)n_misc, (unsigned long long)n_i2f, (unsigned long long)n_fcvt,
              (unsigned long long)n_fma, (unsigned long long)n_fdiv,
              (unsigned long long)(n_misc + n_i2f + n_fcvt + n_fma + n_fdiv));
  return 0;
}
