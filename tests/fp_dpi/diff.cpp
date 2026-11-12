// Differential test: the DPI FP datapath (tb/fp_dpi/fp_dpi.cpp) against the function model executing the same instruction.
// Random F/D instructions (OP-FP of every class, fused multiply-add) with random operands (specials weighted in): the written
// FP / integer register and the accrued flags must agree.  Build: see run.sh (rv32 or rv64 librefcpu, XLEN = 32 / 64).
#include "refcpu_api.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
extern "C" {
uint64_t fp_dpi_res(uint32_t, uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);
uint32_t fp_dpi_flags(uint32_t, uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);
}
static uint64_t rng = 88172645463325252ull;
static uint64_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }
static uint64_t special64() {
  static const uint64_t s[] = {0, 0x8000000000000000ull, 0x3ff0000000000000ull, 0xbff0000000000000ull, 0x7ff0000000000000ull,
    0xfff0000000000000ull, 0x7ff8000000000000ull, 0x7ff0000000000001ull, 0x0000000000000001ull, 0x000fffffffffffffull,
    0x7fefffffffffffffull, 0x4340000000000000ull, 0x41dfffffffc00000ull, 0xc1e0000000000000ull};
  return s[rnd() % (sizeof s / sizeof s[0])];
}
static uint64_t fpval() {   // a mix of random bit patterns, specials and NaN-boxed singles (boxed and improperly boxed)
  switch (rnd() % 6) {
  case 0: return special64();
  case 1: return 0xFFFFFFFF00000000ull | (uint32_t)(special64() >> 32);
  case 2: return 0xFFFFFFFF00000000ull | (uint32_t)rnd();
  case 3: return (uint32_t)rnd();   // not NaN-boxed
  default: return rnd();
  }
}
int main(int argc, char **argv) {
  const long n = argc > 1 ? atol(argv[1]) : 200000;
  RefCpuContext *ctx = refcpu_init(0x80000000u, 0x80000000u);
  long bad = 0, skipped = 0;
  for (long it = 0; it < n; it++) {
    const uint32_t kind = rnd() % 10;
    uint32_t op5, f3 = rnd() % 8, f7 = 0, rs2 = rnd() % 32;
    const uint32_t fmt = (rnd() % 8 == 0) ? 2 : rnd() % 2;
    const uint32_t rs3 = rnd() % 32;
    if (kind < 3) { op5 = 0x10 + rnd() % 4; f7 = rs3 << 2 | fmt; }
    else {
      static const uint32_t f5s[] = {0, 1, 2, 3, 0x0b, 4, 5, 8, 0x14, 0x18, 0x1a, 0x1c, 0x1e, 0x06, 0x10};
      op5 = 0x14; f7 = f5s[rnd() % 15] << 2 | fmt;
      if (rnd() % 2) f3 = (f7 >> 2) == 0x14 ? rnd() % 3 : (rnd() % 5);   // mostly legal rounding modes / function codes
    }
    const uint32_t rd = 1 + rnd() % 30, rs1 = 1 + rnd() % 30;
    rs2 = (f7 >> 2) == 0x08 ? (fmt == 1 ? 0 : 1) : ((f7 >> 2) == 0x18 || (f7 >> 2) == 0x1a) ? rnd() % 4 : (rnd() % 8 == 0 ? rnd() % 32 : (f7 >> 2) == 0x0b || (f7 >> 2) == 0x1c || (f7 >> 2) == 0x1e ? 0 : rs2);
    uint32_t inst = (op5 << 2) | 3u | (rd << 7) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) | (f7 << 25);
    RefCpuState st{};
    refcpu_get_state(ctx, &st);
    for (int i = 0; i < 32; i++) { st.gpr[i] = (refcpu_xlen_t)rnd(); st.fpr[i] = fpval(); }
    st.gpr[0] = 0;
    const uint32_t frm = rnd() % 5;
    st.fcsr = frm << 5;
    st.csr[7] = (st.csr[7] & ~(3u << 13)) | (1u << 13);   // mstatus.FS = Initial (enabled)
    st.pc = 0x80000000u;
    refcpu_store_word(ctx, 0x80000000u, inst);
    refcpu_set_state(ctx, &st);
    refcpu_step(ctx, 1);
    RefCpuState after{};
    refcpu_get_state(ctx, &after);
    const bool trapped = after.pc != 0x80000004u;
    const uint32_t xlen = XLEN;
    const uint64_t res = fp_dpi_res(op5, f3, (f7 << 5) | rs2, op5 < 0x14 ? st.fpr[rs1] : st.fpr[rs1], st.fpr[(inst >> 20) & 31],
                                    st.fpr[rs3], st.gpr[rs1], frm, xlen);
    const uint32_t flags = fp_dpi_flags(op5, f3, (f7 << 5) | rs2, st.fpr[rs1], st.fpr[(inst >> 20) & 31], st.fpr[rs3], st.gpr[rs1],
                                        frm, xlen);
    if (trapped) {   // illegal instruction in the model: the DPI function must have returned "nothing" (0, no flags)
      if (res != 0 || flags != 0) { if (bad++ < 10) printf("TRAP MISMATCH inst %08x res %llx flags %x\n", inst, (unsigned long long)res, flags); }
      skipped++;
      continue;
    }
    const uint32_t fclass_int = ((f7 >> 2) == 0x14 || (f7 >> 2) == 0x18 || (f7 >> 2) == 0x1c) && op5 == 0x14;
    uint64_t want;
    if (fclass_int) want = after.gpr[rd]; else want = after.fpr[rd];
    uint64_t got = res;
    if (fclass_int) got &= (xlen == 64 ? ~0ull : 0xFFFFFFFFull);
    if (got != want || flags != (after.fcsr & 0x1Fu)) {
      if (bad++ < 10) printf("MISMATCH inst %08x frm %u: dpi res %016llx flags %02x, model %016llx flags %02x\n", inst, frm,
                             (unsigned long long)got, flags, (unsigned long long)want, after.fcsr & 0x1Fu);
    }
  }
  printf("%ld cases (%ld trapped in the model), mismatches: %ld\n", n, skipped, bad);
  refcpu_destroy(ctx);
  return bad != 0;
}
