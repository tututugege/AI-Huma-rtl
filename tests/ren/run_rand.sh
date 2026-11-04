#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/ren/rand_*.trc.
#   usage: bash tests/ren/run_rand.sh     (iogen is run here from spec/ren.io)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-$ROOT/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/ren.io build/ren >/dev/null
# no -DNDEBUG: the reference's Assert()s (free-list sanity etc.) stay active, so stimulus is checked to be legal
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/ren tests/ren/rand_trace.cpp "$REF/back-end/Ren.cpp" -o build/ren/rand_trace
mkdir -p traces/ren
#            file                          seed  cycles areg_pool p_dest%
build/ren/rand_trace traces/ren/rand_a.trc 1     100000 4         70
build/ren/rand_trace traces/ren/rand_b.trc 2     100000 8         85
build/ren/rand_trace traces/ren/rand_c.trc 3     100000 31        50
build/ren/rand_trace traces/ren/rand_d.trc 4     100000 2         95
