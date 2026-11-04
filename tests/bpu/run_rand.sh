#!/usr/bin/env bash
# Build the BPU random generator (links nothing but the reference headers) and write traces/bpu/rand_<seed>.trc, then replay.
#   usage: bash tests/bpu/run_rand.sh <cycles> <seed>...      (REFSIM = refsim_tap source tree, read only)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/AI-Huma/rtl/refsim_tap}
N=$1; shift
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
         MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end \
         axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
         axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/bpu.io build/bpu >/dev/null
clang++ -std=c++2a -O2 -w -DNDEBUG "${INC[@]}" -Iharness/include -Ibuild/bpu -Itests/front_basic \
  -DMODFIELDS='"bpu_fields.h"' -DMOD=bpu tests/bpu/rand_trace.cpp -o build/bpu/genr
mkdir -p traces/bpu
for s in "$@"; do build/bpu/genr traces/bpu/rand_$s.trc $s $N; done
