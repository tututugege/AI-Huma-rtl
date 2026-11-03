#!/usr/bin/env bash
# Build the icache random-stimulus generator against the (read-only) reference sources and write traces/icache/rand_*.trc.
#   usage: bash tests/icache/run_rand.sh [cycles] [seed...]     env REFSIM = refsim copy WITH the icache tap patch (default: refsim_tap once merged)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim_tap}
N=${1:-200000}; [ $# -gt 0 ] && shift
SEEDS=${@:-1 2 3 4}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include \
         GenSimpoint/include/api legacy/mmu/include front-end front-end/icache axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
         axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/icache.io build/icache >/dev/null
OUT=build/icache/gen; mkdir -p $OUT
# no -DNDEBUG: reference Assert()s stay on
for f in front-end/icache/icache.cpp front-end/icache/ICacheTop.cpp front-end/icache/icache_module.cpp back-end/Lsu/TlbMmu.cpp MemSubSystem/PtwWalker.cpp; do
  o=$OUT/$(basename $f .cpp).o
  [ "$o" -nt "$REF/$f" ] || clang++ -std=c++2a -O1 -w "${INC[@]}" -c "$REF/$f" -o "$o"
done
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/icache tests/icache/rand_trace.cpp $OUT/*.o -o build/icache/rand_trace
mkdir -p traces/icache
for s in $SEEDS; do build/icache/rand_trace traces/icache/rand_$s.trc $s $N; done
