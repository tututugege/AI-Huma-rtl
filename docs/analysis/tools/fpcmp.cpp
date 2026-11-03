// build: clang++ -std=c++17 -O2 -w -I$SRC/libs/include -I$SRC/back-end/Exu/include fpcmp.cpp $SRC/libs/softfloat.a -o fpcmp   (SRC = reference simulator src dir)
// usage: ./fpcmp [random pairs per rounding mode, default 2000000]
// Compare the gate-level netlists (fadd.h / fmul.h) with Berkeley softfloat (what Exu actually uses: FPUSoftfloat).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
extern "C" {
#include "softfloat.h"
#include "fadd.h"
#include "fmul.h"
}
static void u2b(uint32_t v, bool *a, int n) { for (int i = 0; i < n; i++) a[i] = (v >> i) & 1; }
static uint32_t b2u(const bool *a, int n) { uint32_t v = 0; for (int i = 0; i < n; i++) if (a[i]) v |= 1u << i; return v; }
static void net(int which, uint32_t a, uint32_t b, uint32_t rm, uint32_t &res, uint32_t &fl) {
  bool pi[67] = {}, po[37] = {};
  u2b(a, pi, 32); u2b(b, pi + 32, 32); u2b(rm, pi + 64, 3);
  if (which == 0) fadd_io_generator(pi, po); else fmul_io_generator(pi, po);
  res = b2u(po, 32); fl = b2u(po + 32, 5);
}
static uint32_t corner[] = {0, 0x80000000, 0x00000001, 0x80000001, 0x007fffff, 0x00800000, 0x3f800000, 0xbf800000, 0x7f7fffff,
  0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0x7fa00000, 0xffc00000, 0x7fffffff, 0x3f000000, 0x40000000, 0x00400000,
  0x33800000, 0x4b000000, 0x4b800000, 0x7e800000, 0x01000000, 0x3fc00000};
int main(int argc, char **argv) {
  long nrand = argc > 1 ? atol(argv[1]) : 2000000;
  std::mt19937_64 rng(12345);
  const char *nm[2] = {"fadd", "fmul"};
  softfloat_detectTininess = softfloat_tininess_afterRounding;
  for (int w = 0; w < 2; w++) {
    for (int rmmode = 0; rmmode < 8; rmmode++) {
      long tot = 0, mres = 0, mfl = 0, mnan = 0; int shown = 0;
      auto test = [&](uint32_t a, uint32_t b) {
        float32_t fa{a}, fb{b};
        softfloat_roundingMode = rmmode > 4 ? 0 : rmmode; softfloat_exceptionFlags = 0;
        uint32_t ref = (w == 0 ? f32_add(fa, fb) : f32_mul(fa, fb)).v;
        uint32_t rflags = softfloat_exceptionFlags;
        uint32_t res, fl; net(w, a, b, rmmode, res, fl);
        tot++;
        if (res != ref) { mres++; if (((ref & 0x7f800000) == 0x7f800000 && (ref & 0x7fffff)) && ((res & 0x7f800000) == 0x7f800000 && (res & 0x7fffff))) mnan++; if (shown++ < 3 && rmmode == 0) std::printf("  %s rm=%d a=%08x b=%08x softfloat=%08x netlist=%08x\n", nm[w], rmmode, a, b, ref, res); }
        if (fl != rflags) mfl++;
      };
      for (uint32_t a : corner) for (uint32_t b : corner) test(a, b);
      for (long i = 0; i < nrand; i++) {
        uint64_t r = rng();
        uint32_t a = (uint32_t)r, b = (uint32_t)(r >> 32);
        // bias exponents towards close values (for add cancellation) every other sample
        if (i & 1) { b = (b & 0x807fffff) | (a & 0x7f800000); if (i & 2) b = (b & ~0x7f800000u) | (((a >> 23) + (rng() % 5) - 2) & 0xff) << 23; }
        test(a, b);
      }
      std::printf("%s rm=%d: %ld tests, result mismatches %ld (of which both NaN %ld), fflag mismatches %ld\n", nm[w], rmmode, tot, mres, mnan, mfl);
    }
  }
}
