#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/tlb_mmu/rand_*.trc.
#   usage: bash tests/tlb_mmu/run_rand.sh     (iogen is run here from spec/tlb_mmu.io)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/tlb_mmu.io build/tlb_mmu >/dev/null
# no -DNDEBUG: the reference's Assert()s stay active, so a stimulus that the model would reject aborts the run
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/tlb_mmu tests/tlb_mmu/rand_trace.cpp \
  "$REF/back-end/Lsu/TlbMmu.cpp" "$REF/MemSubSystem/PtwWalker.cpp" -o build/tlb_mmu/rand_trace
mkdir -p traces/tlb_mmu
#            file                              seed cycles p_stale(permille)
build/tlb_mmu/rand_trace traces/tlb_mmu/rand_a.trc 1 200000
build/tlb_mmu/rand_trace traces/tlb_mmu/rand_b.trc 2 200000
build/tlb_mmu/rand_trace traces/tlb_mmu/rand_c.trc 3 200000
build/tlb_mmu/rand_trace traces/tlb_mmu/rand_d.trc 4 200000
build/tlb_mmu/rand_trace traces/tlb_mmu/rand_stale_a.trc 5 100000 5
build/tlb_mmu/rand_trace traces/tlb_mmu/rand_stale_b.trc 6 100000 20
