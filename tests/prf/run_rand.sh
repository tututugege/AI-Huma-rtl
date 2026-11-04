#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/prf/rand_*.trc.
#   usage: bash tests/prf/run_rand.sh     (needs spec/prf.io already iogen'ed: build/prf/prf_fields.h, e.g. after scripts/record.sh)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-$ROOT/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/prf.io build/prf >/dev/null
clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -Iharness/include -Ibuild/prf tests/prf/rand_trace.cpp "$REF/back-end/Prf.cpp" -o build/prf/rand_trace
mkdir -p traces/prf
#            file                          seed  cycles pool(recent preg window) p_load%
build/prf/rand_trace traces/prf/rand_a.trc 1     40000 6    40
build/prf/rand_trace traces/prf/rand_b.trc 2     40000 40   25
build/prf/rand_trace traces/prf/rand_c.trc 3     40000 100  10
