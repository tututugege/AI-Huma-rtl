#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/lsu/rand_*.trc.
#   usage: bash tests/lsu/run_rand.sh [cycles]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-$ROOT/refsim}
CYC=${1:-20000}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
         MemSubSystem/include diff/include function-model/include/api legacy/mmu/include front-end axi-interconnect-kit/include \
         axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do
  INC+=("-I$REF/$d")
done
python3 harness/tools/iogen.py spec/lsu.io build/lsu >/dev/null
python3 tests/lsu/gen_record_inc.py spec/lsu.io build/lsu/rand_record.inc
mkdir -p build/lsu_rand traces/lsu
SRC=(tests/lsu/rand_trace.cpp "$REF/back-end/Lsu/RealLsu.cpp" "$REF/back-end/Lsu/RealLsuPerf.cpp" "$REF/MemSubSystem/DcacheConfig.cpp")
# no -DNDEBUG: the reference model's own Assert()s are armed and check the legality of the stimulus
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/lsu "${SRC[@]}" -o build/lsu_rand/rand_trace
for s in 1 2 3 4; do
  build/lsu_rand/rand_trace "traces/lsu/rand_$s.trc" "$s" "$CYC"
done
for s in 5 6 7 8 9 10 11 12; do
  build/lsu_rand/rand_trace "traces/lsu/rand_$s.trc" "$s" $((CYC * 2))
done
