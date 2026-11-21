#!/usr/bin/env bash
# Equivalence test: verify that the SYNTHESIS hardware trees and fast simulation paths of
# ttg_first_set, ttg_onehot_mux, ttg_popcount, ttg_pick_k are bit-identical over 100k random vectors.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
W=${1:-$R/build/test_common_prims}
rm -rf "$W" && mkdir -p "$W"

cat > "$W/tb_prims.sv" <<'EOF'
`default_nettype none
module tb_prims #(
  parameter int N = 64,
  parameter int K = 6,
  parameter int W = 32
) (
  input  logic [N-1:0]  req,
  input  logic [W-1:0]  data [N],
  output logic [N-1:0]  fs_oh,
  output logic          fs_any,
  output logic [W-1:0]  mux_out,
  output logic [$clog2(N+1)-1:0] pc_out,
  output logic [N-1:0]  pk_oh [K],
  output logic [K-1:0]  pk_v
);
  ttg_first_set  #(.N(N))        u_fs  (.req(req), .onehot(fs_oh), .any(fs_any));
  ttg_onehot_mux #(.N(N), .W(W)) u_mux (.sel(req), .data(data), .out(mux_out));
  ttg_popcount   #(.N(N))        u_pc  (.bits(req), .count(pc_out));
  ttg_pick_k     #(.N(N), .K(K)) u_pk  (.req(req), .pick_oh(pk_oh), .valid(pk_v));
endmodule
`default_nettype wire
EOF

cat > "$W/main.cpp" <<'EOF'
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vtb_sim.h"
#include "Vtb_syn.h"

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static uint64_t next_u64() {
  uint64_t x = rng;
  x ^= x << 13; x ^= x >> 7; x ^= x << 17;
  return rng = x;
}

int main() {
  Vtb_sim sim;
  Vtb_syn syn;
  const int TRIALS = 100000;
  for (int t = 0; t < TRIALS; ++t) {
    uint64_t r = (t == 0) ? 0ULL : (t == 1) ? ~0ULL : (t < 66) ? (1ULL << (t - 2)) : next_u64();
    if (t >= 66 && (t & 3) == 0) r &= next_u64();   // sparse masks
    if (t >= 66 && (t & 7) == 1) r &= next_u64() & next_u64();
    sim.req = syn.req = r;
    for (int i = 0; i < 64; ++i) {
      uint32_t d = uint32_t(next_u64());
      sim.data[i] = syn.data[i] = d;
    }
    sim.eval();
    syn.eval();
    if (sim.fs_oh != syn.fs_oh || sim.fs_any != syn.fs_any ||
        sim.mux_out != syn.mux_out || sim.pc_out != syn.pc_out || sim.pk_v != syn.pk_v) {
      std::fprintf(stderr, "MISMATCH at trial %d req=%016llx\n", t, (unsigned long long)r);
      return 1;
    }
    for (int k = 0; k < 6; ++k) {
      if (sim.pk_oh[k] != syn.pk_oh[k]) {
        std::fprintf(stderr, "PICK_K MISMATCH at trial %d k=%d req=%016llx\n", t, k, (unsigned long long)r);
        return 1;
      }
    }
  }
  std::printf("common_prims: %d random trials PASS (0 mismatches across first_set, onehot_mux, popcount, pick_k)\n", TRIALS);
  return 0;
}
EOF

cd "$W"
SRCS=("$R/rtl/common/ttg_first_set.sv" "$R/rtl/common/ttg_onehot_mux.sv" "$R/rtl/common/ttg_popcount.sv" "$R/rtl/common/ttg_pick_k.sv" "$W/tb_prims.sv")
verilator --cc --prefix Vtb_sim -Mdir obj_sim -Wno-fatal -Wno-lint --top-module tb_prims "${SRCS[@]}" >/dev/null
verilator --cc --prefix Vtb_syn -Mdir obj_syn -DSYNTHESIS -Wno-fatal -Wno-lint --top-module tb_prims "${SRCS[@]}" >/dev/null
make -C obj_sim -f Vtb_sim.mk -j4 >/dev/null
make -C obj_syn -f Vtb_syn.mk -j4 >/dev/null
VI=$(verilator --getenv VERILATOR_ROOT)/include
g++ -O2 -std=c++2a -Iobj_sim -Iobj_syn -I"$VI" -I"$VI/vltstd" \
  "$W/main.cpp" obj_sim/Vtb_sim__ALL.a obj_syn/Vtb_syn__ALL.a "$VI/verilated.cpp" "$VI/verilated_threads.cpp" \
  -lpthread -o test_prims
./test_prims
