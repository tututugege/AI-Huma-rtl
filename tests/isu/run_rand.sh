#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/isu/rand_*.trc.
#   usage: bash tests/isu/run_rand.sh [cycles]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/AI-Huma/rtl/refsim}
CYC=${1:-30000}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/isu.io build/isu >/dev/null
python3 tests/isu/gen_record_inc.py spec/isu.io build/isu/rand_record.inc
# no -DNDEBUG: the reference model's own Assert()s (queue overflow, delayed-wake slot shortage, op range) are armed
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/isu tests/isu/rand_trace.cpp "$REF/back-end/Isu.cpp" -o build/isu/rand_trace
mkdir -p traces/isu
#            file                         seed  cycles
build/isu/rand_trace traces/isu/rand_a.trc 1 "$CYC"
build/isu/rand_trace traces/isu/rand_b.trc 2 "$CYC"
build/isu/rand_trace traces/isu/rand_c.trc 3 "$CYC"
build/isu/rand_trace traces/isu/rand_d.trc 4 "$CYC"
