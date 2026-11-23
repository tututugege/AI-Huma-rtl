#include "Vdiv_check_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static uint64_t ref_div(uint64_t a, uint64_t b, int f3, bool word) {
  if (word) {
    int32_t  sa = (int32_t)a,  sb = (int32_t)b;
    uint32_t ua = (uint32_t)a, ub = (uint32_t)b;
    int32_t r = 0;
    if (f3 == 0) { // divw
      if (sb == 0) r = -1;
      else if (sa == INT32_MIN && sb == -1) r = INT32_MIN;
      else r = sa / sb;
    } else if (f3 == 1) { // divuw
      r = (ub == 0) ? -1 : (int32_t)(ua / ub);
    } else if (f3 == 2) { // remw
      if (sb == 0) r = sa;
      else if (sa == INT32_MIN && sb == -1) r = 0;
      else r = sa % sb;
    } else { // remuw
      r = (ub == 0) ? (int32_t)ua : (int32_t)(ua % ub);
    }
    return (uint64_t)(int64_t)r;
  } else {
    int64_t  sa = (int64_t)a,  sb = (int64_t)b;
    uint64_t ua = a,           ub = b;
    if (f3 == 0) { // div
      if (sb == 0) return ~0ULL;
      if (sa == INT64_MIN && sb == -1) return (uint64_t)INT64_MIN;
      return (uint64_t)(sa / sb);
    } else if (f3 == 1) { // divu
      return (ub == 0) ? ~0ULL : (ua / ub);
    } else if (f3 == 2) { // rem
      if (sb == 0) return (uint64_t)sa;
      if (sa == INT64_MIN && sb == -1) return 0;
      return (uint64_t)(sa % sb);
    } else { // remu
      return (ub == 0) ? ua : (ua % ub);
    }
  }
}

static uint64_t xorshift64(uint64_t &s) {
  s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s;
}

int main() {
  Vdiv_check_top top;
  auto tick = [&]() { top.clk = 0; top.eval(); top.clk = 1; top.eval(); };
  top.rst_n = 0; top.accept = 0; top.run = 0; top.func3 = 0; top.is_word = 0; top.a = 0; top.b = 0;
  tick(); tick();
  top.rst_n = 1;

  const std::vector<uint64_t> corners = {
    0ULL, 1ULL, 2ULL, 3ULL, 4ULL, 7ULL, 15ULL,
    ~0ULL, ~1ULL, ~2ULL, ~3ULL,
    0x7fffffffULL, 0x80000000ULL, 0xffffffffULL, 0x100000000ULL,
    0x7fffffffffffffffULL, 0x8000000000000000ULL,
    0xffffffff80000000ULL, 0xffffffff7fffffffULL,
    0xdeadbeefcafebabeULL, 0x0123456789abcdefULL
  };

  uint64_t tested = 0;
  auto run_one = [&](uint64_t a, uint64_t b, int f3, bool word) {
    top.accept = 1; top.run = 0; top.func3 = f3; top.is_word = word; top.a = a; top.b = b;
    top.clk = 0; top.eval();
    if (top.lat_beh != top.lat_str || top.lat_beh < 1 || top.lat_beh > 16) {
      std::fprintf(stderr, "FAIL LAT a=%016llx b=%016llx f3=%d w=%d lat_beh=%u lat_str=%u\n",
                   (unsigned long long)a, (unsigned long long)b, f3, (int)word, top.lat_beh, top.lat_str);
      std::exit(1);
    }
    const int lat_m1 = top.lat_beh;
    top.clk = 1; top.eval();
    top.accept = 0; top.run = 1;
    for (int i = 0; i < lat_m1; i++) tick();
    top.run = 0;
    top.eval();
    uint64_t exp = ref_div(a, b, f3, word);
    if (top.res_beh != exp || top.res_str != exp) {
      std::fprintf(stderr, "FAIL a=%016llx b=%016llx f3=%d w=%d lat_m1=%d exp=%016llx beh=%016llx str=%016llx\n",
                   (unsigned long long)a, (unsigned long long)b, f3, (int)word, lat_m1,
                   (unsigned long long)exp, (unsigned long long)top.res_beh, (unsigned long long)top.res_str);
      std::exit(1);
    }
    tested++;
  };

  // Exhaustive corners x corners x 4 ops x 2 widths
  for (uint64_t a : corners)
    for (uint64_t b : corners)
      for (int w = 0; w < 2; w++)
        for (int f3 = 0; f3 < 4; f3++)
          run_one(a, b, f3, w != 0);

  // Random tests including small divisors (1..15) and full 64-bit randoms
  uint64_t rng = 0x123456789abcdef1ULL;
  for (int i = 0; i < 100000; i++) {
    uint64_t a = xorshift64(rng);
    uint64_t b = xorshift64(rng);
    if ((i & 7) == 0) b &= 0xfULL;          // small divisors 0..15 (hits accept fast-path!)
    else if ((i & 7) == 1) b &= 0xffffULL;  // medium divisors
    else if ((i & 7) == 2) a >>= (xorshift64(rng) & 63);
    int f3 = (int)(xorshift64(rng) & 3);
    bool w = (xorshift64(rng) & 1) != 0;
    run_one(a, b, f3, w);
  }

  std::printf("div_check: %llu divisions PASS (STRUCT=1 == STRUCT=0 == C++ ref)\n", (unsigned long long)tested);
  return 0;
}
