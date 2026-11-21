#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vren_elim_sel.h"
#include "verilated.h"

static constexpr int N = 8;
static constexpr int RAT_NUM = 33;
static constexpr int MAX_REFS = 7;

static uint64_t rng_state = 0x9e3779b97f4a7c15ULL;
static uint32_t xorshift32() {
  uint64_t x = rng_state;
  x ^= x << 13;
  x ^= x >> 7;
  x ^= x << 17;
  rng_state = x;
  return static_cast<uint32_t>(x);
}

int main() {
  Vren_elim_sel dut;
  constexpr int TRIALS = 100000;
  int total_elim = 0, total_bypass_elim = 0, total_oob_blocked = 0;

  for (int t = 0; t < TRIALS; t++) {
    uint8_t inst_valid = 0, move_shape = 0, dest_en = 0, dest_fp = 0;
    uint8_t dest_areg[N], src1_areg[N], src1_rat[N];
    uint8_t spec_rat[RAT_NUM];

    // Bias spec_rat toward small pool of pregs so ref counts hit boundary 5..9 frequently
    int pool = (t % 3 == 0) ? 8 : ((t % 3 == 1) ? 16 : 64);
    for (int e = 0; e < RAT_NUM; e++) {
      spec_rat[e] = static_cast<uint8_t>(xorshift32() % pool);
    }
    // Bias aregs toward small set so intra-group chains (mv -> mv -> mv) happen frequently
    int apool = (t % 2 == 0) ? 4 : 16;
    for (int i = 0; i < N; i++) {
      if ((xorshift32() % 10) < 9) inst_valid |= (1u << i);
      if ((xorshift32() % 10) < 6) move_shape |= (1u << i);
      if (i < N - 1) {
        if ((xorshift32() % 10) < 8) dest_en |= (1u << i);
        if ((xorshift32() % 10) < 2) dest_fp |= (1u << i);
      }
      dest_areg[i] = static_cast<uint8_t>(1 + (xorshift32() % apool));
      src1_areg[i] = static_cast<uint8_t>(1 + (xorshift32() % apool));
      src1_rat[i]  = spec_rat[src1_areg[i]];
    }

    // Drive DUT
    dut.inst_valid = inst_valid;
    dut.move_shape = move_shape;
    dut.dest_en    = dest_en;
    dut.dest_fp    = dest_fp;
    for (int i = 0; i < N; i++) {
      dut.dest_areg[i] = dest_areg[i];
      dut.src1_areg[i] = src1_areg[i];
      dut.src1_rat[i]  = src1_rat[i];
    }
    // Pack spec_rat (RAT_NUM * 8 bits = 264 bits -> VlWide<9>)
    for (int w = 0; w < 9; w++) dut.spec_rat[w] = 0;
    for (int e = 0; e < RAT_NUM; e++) {
      int bit = e * 8;
      dut.spec_rat[bit / 32] |= (static_cast<uint32_t>(spec_rat[e]) << (bit % 32));
    }
    dut.eval();

    // Golden reference (exact Ren::elim_refs_ok)
    uint8_t ref_elim = 0;
    for (int i = 0; i < N; i++) {
      bool v = (inst_valid >> i) & 1;
      bool ms = (move_shape >> i) & 1;
      if (!v || !ms) continue;
      int older = 0, producer = -1;
      for (int j = 0; j < i; j++) {
        bool jv = (inst_valid >> j) & 1;
        bool jde = (dest_en >> j) & 1;
        bool jfp = (dest_fp >> j) & 1;
        if (!jv || !jde) continue;
        if (dest_areg[j] != 0 && !jfp && dest_areg[j] == src1_areg[i]) producer = j;
        older++;
      }
      bool ok = false;
      if (producer >= 0) {
        if ((i - producer) < MAX_REFS) {
          ok = !((ref_elim >> producer) & 1);
          if (ok) total_bypass_elim++;
        } else {
          total_oob_blocked++;
        }
      } else {
        int refs = 0;
        for (int e = 0; e < RAT_NUM; e++)
          if (spec_rat[e] == src1_rat[i]) refs++;
        ok = (refs + older + 1 <= MAX_REFS);
      }
      if (ok) {
        ref_elim |= (1u << i);
        total_elim++;
      }
    }

    if (dut.elim != ref_elim) {
      std::printf("MISMATCH at trial %d: dut=0x%02x ref=0x%02x\n", t, dut.elim, ref_elim);
      return 1;
    }
  }
  std::printf("PASS ren_elim_sel equiv: %d trials, 0 mismatches (elim=%d, bypass_elim=%d, oob_blocked=%d)\n",
              TRIALS, total_elim, total_bypass_elim, total_oob_blocked);
  return 0;
}
