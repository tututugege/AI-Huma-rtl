// Equivalence check of a generated netlist SV module against the C++ netlist function it was generated from.
// Same random/corner/bit-flip vectors for every build.  Compile with -DNET_HDR="Vxxx.h" -DNET_T=Vxxx
// -DNET_FN=fadd_io_generator -DNET_HDR2="fadd.h" -DWITH_FLAGS=0/1.
//   usage: netlist_tb [random vectors (default 10000000)]
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include NET_HDR
extern "C" {
#include NET_HDR2
}
static NET_T *dut;
static long checked = 0, bad = 0;
static void run(uint32_t a, uint32_t b, uint32_t rm) {
  bool pi[67] = {}, po[37] = {};
  for (int i = 0; i < 32; i++) { pi[i] = (a >> i) & 1; pi[32 + i] = (b >> i) & 1; }
  for (int i = 0; i < 3; i++) pi[64 + i] = (rm >> i) & 1;
  NET_FN(pi, po);
  uint32_t r = 0, f = 0;
  for (int i = 0; i < 32; i++) r |= uint32_t(po[i]) << i;
  for (int i = 0; i < 5; i++) f |= uint32_t(po[32 + i]) << i;
  dut->a = a; dut->b = b; dut->rm = rm; dut->eval();
  bool ok = dut->result == r;
#if WITH_FLAGS
  ok = ok && dut->fflags == f;
#endif
  checked++;
  if (!ok) { if (bad++ < 5) std::printf("MISMATCH a=%08x b=%08x rm=%u sv=%08x c++=%08x\n", a, b, rm, (unsigned)dut->result, r); }
}
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 10000000;
  dut = new NET_T;
  std::mt19937_64 rng(2024);
  static const uint32_t corner[] = {0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000, 0x3f800000, 0xbf800000, 0x7f7fffff,
    0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0x7fa00000, 0xffc00000, 0x7fffffff, 0x3f000000, 0x40000000};
  for (uint32_t a : corner) for (uint32_t b : corner) for (uint32_t rm = 0; rm < 8; rm++) run(a, b, rm);
  for (long i = 0; i < n; i++) {
    uint64_t r = rng();
    uint32_t a = (uint32_t)r, b = (uint32_t)(r >> 32), rm = (uint32_t)(rng() & 7);
    if (i & 1) b = (b & 0x807fffff) | (a & 0x7f800000);
    run(a, b, rm);
    if ((i & 15) == 0) {  // single-bit sensitivity around this vector
      for (int k = 0; k < 67; k++) {
        uint32_t aa = a, bb = b, mm = rm;
        if (k < 32) aa ^= 1u << k; else if (k < 64) bb ^= 1u << (k - 32); else mm ^= 1u << (k - 64);
        run(aa, bb, mm);
      }
    }
  }
  std::printf("%s: %ld vectors, %ld mismatches\n", bad ? "FAIL" : "PASS", checked, bad);
  return bad != 0;
}
