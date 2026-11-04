#!/usr/bin/env bash
# Build the constrained-random Csr trace generator against the (read-only) reference sources and write traces/csr/rand*.trc.
#   usage: bash tests/csr/run_rand.sh     (needs build/csr/csr_fields.h: run scripts/record.sh csr once)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-$ROOT/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include function-model/include/api legacy/mmu/include front-end axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/csr.io build/csr >/dev/null
mkdir -p build/tb traces/csr
# no -DNDEBUG: the reference's Assert()s stay on, so the stimulus is checked to be legal
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/csr tests/csr/rand_trace.cpp "$REF/back-end/Exu/Csr.cpp" \
  -o build/tb/csr_rand -Wl,-undefined,dynamic_lookup
for p in 0 1 2 3; do build/tb/csr_rand traces/csr/rand$p.trc $((p + 11)) 60000 $p; done
