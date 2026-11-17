// mul_check: random + corner operands through both multipliers, compare every cycle (the result of cycle t belongs to the operands of t-2),
// and against a C++ reference product.
#include "Vmul_check_top.h"
#include <cstdint>
#include <cstdio>
#include <random>
static uint64_t ref(unsigned f3, bool word, uint64_t a, uint64_t b) {
  __int128 sa = (__int128)(int64_t)a, ua = (__int128)a, sb = (__int128)(int64_t)b, ub = (__int128)b;
  __int128 p = f3 == 1 ? sa * sb : f3 == 2 ? sa * ub : ua * ub;
  unsigned __int128 u = (unsigned __int128)p;
  if (word) return (uint64_t)(int64_t)(int32_t)(uint32_t)u;
  return f3 == 0 ? (uint64_t)u : (uint64_t)(u >> 64);
}
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vmul_check_top *t = new Vmul_check_top;
  std::mt19937_64 rng(1);
  const uint64_t corners[] = {0, 1, 2, ~0ull, 0x8000000000000000ull, 0x7fffffffffffffffull, 0xffffffff, 0x80000000, 0x100000000ull, 0xdeadbeefcafef00dull};
  struct In { unsigned f3; bool w; uint64_t a, b; } hist[3] = {};
  long errs = 0, n = 0;
  for (long it = 0; it < 4000000; it++) {
    In in;
    in.f3 = rng() & 3;
    in.w = (in.f3 == 0) && (rng() & 1);
    auto pick = [&]() { uint64_t r = rng(); switch (r & 7) { case 0: return corners[(r >> 8) % 10]; case 1: return (uint64_t)(int64_t)(int32_t)(r >> 8); default: return (uint64_t)rng(); } };
    in.a = pick();
    in.b = pick();
    t->func3 = in.f3; t->is_word = in.w; t->a = in.a; t->b = in.b;
    t->clk = 0; t->eval();
    // before the edge the outputs show the operands applied two edges ago (hist[1] holds them)
    if (it >= 2) {
      const In &o = hist[1];
      uint64_t e = ref(o.f3, o.w, o.a, o.b);
      n++;
      if (t->r_beh != e || t->r_tree != e) {
        if (errs++ < 10) std::printf("MISMATCH f3=%u w=%d a=%016llx b=%016llx ref=%016llx beh=%016llx tree=%016llx\n", o.f3, o.w, (unsigned long long)o.a, (unsigned long long)o.b, (unsigned long long)e, (unsigned long long)t->r_beh, (unsigned long long)t->r_tree);
      }
    }
    t->clk = 1; t->eval();
    hist[1] = hist[0]; hist[0] = in;
  }
  std::printf("mul_check: %ld products compared, %ld mismatches\n", n, errs);
  return errs != 0;
}
