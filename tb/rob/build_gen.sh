#!/usr/bin/env bash
# Build the constrained-random Rob trace generator against the (read-only) reference sources and write traces/rob/rand_*.trc.
#   usage: bash tb/rob/build_gen.sh [run]      (needs build/rob/rob_fields.h: run scripts/record.sh rob once)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
mkdir -p "$ROOT/build/tb"
clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -I"$ROOT/harness/include" -I"$ROOT/build/rob" \
  "$ROOT/tb/rob/gen_rand.cpp" "$REF/back-end/Rob.cpp" -o "$ROOT/build/tb/gen_rand" -Wl,-undefined,dynamic_lookup
if [ "${1:-}" = run ]; then
  mkdir -p "$ROOT/traces/rob"
  for p in 0 1 2 3 4 5; do "$ROOT/build/tb/gen_rand" "$ROOT/traces/rob/rand$p.trc" $((p + 1)) 40000 $p; done
fi
