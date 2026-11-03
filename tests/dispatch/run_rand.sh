#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/dispatch/rand_*.trc.
#   usage: bash tests/dispatch/run_rand.sh     (iogen is run here for the field table)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/dispatch.io build/dispatch >/dev/null
clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -Iharness/include -Ibuild/dispatch tests/dispatch/rand_trace.cpp "$REF/back-end/Dispatch.cpp" -o build/dispatch/rand_trace
mkdir -p traces/dispatch
#            file                              seed  cycles tight%
build/dispatch/rand_trace traces/dispatch/rand_a.trc 1 30000 40
build/dispatch/rand_trace traces/dispatch/rand_b.trc 2 30000 80
build/dispatch/rand_trace traces/dispatch/rand_c.trc 3 30000 10
