// Random equivalence test of ren_elim_sel against its definition (docs/modules/ren.md, move elimination):
//   elim[i] = cand[i] && (no older valid lane j < i with raw_hit_src1[i][j]  ||  !elim[p]),  p = the youngest such j,
//   cand[i] = inst_valid[i] && move_shape[i].
// Vectors are biased toward long intra-group move chains. Prints PASS / the first mismatch.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vren_elim_sel.h"
#include "verilated.h"

static constexpr int N = 8;
static uint64_t rs = 0x9e3779b97f4a7c15ULL;
static uint32_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return static_cast<uint32_t>(rs); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const long trials = argc > 1 ? std::atol(argv[1]) : 2000000;
  Vren_elim_sel dut;
  long n_elim = 0, n_chain = 0;
  for (long t = 0; t < trials; t++) {
    uint8_t valid = 0, move = 0, hit[N] = {};
    const int pv = 6 + rnd() % 5, pm = 3 + rnd() % 8, ph = 1 + rnd() % 6;   // densities in tenths
    for (int i = 0; i < N; i++) {
      if (int(rnd() % 10) < pv) valid |= 1u << i;
      if (int(rnd() % 10) < pm) move |= 1u << i;
      for (int j = 0; j < N; j++) if (int(rnd() % 10) < ph) hit[i] |= 1u << j;   // also j >= i: must be ignored
    }
    dut.inst_valid = valid; dut.move_shape = move;
    for (int i = 0; i < N; i++) dut.raw_hit_src1[i] = hit[i];
    dut.eval();
    uint8_t ref = 0;
    for (int i = 0; i < N; i++) {
      if (!((valid >> i) & 1) || !((move >> i) & 1)) continue;
      int p = -1;
      for (int j = i - 1; j >= 0; j--) if (((valid >> j) & 1) && ((hit[i] >> j) & 1)) { p = j; break; }
      if (p < 0 || !((ref >> p) & 1)) ref |= 1u << i;
      if (p >= 0) n_chain++;
    }
    if (dut.elim != ref) {
      std::printf("MISMATCH trial %ld: valid=%02x move=%02x dut=%02x ref=%02x\n", t, valid, move, dut.elim, ref);
      return 1;
    }
    n_elim += __builtin_popcount(ref);
  }
  std::printf("ren_elim_sel PASS: %ld vectors, %ld eliminated moves, %ld bypass chains\n", trials, n_elim, n_chain);
  return 0;
}
