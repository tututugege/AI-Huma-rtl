#!/usr/bin/env bash
# byte-identity check: original refsim_tap vs hooked copy (hooks off / hooks on with the stat plugin)
S=$(cd "$(dirname "$0")" && pwd)
B=/Users/ruyaoh/personal/tututugege-trace/build
ORIG=/Users/ruyaoh/personal/tututugege-rtl/refsim_tap
for p in "$B/tests/dcache-mshr-pressure/dcache-mshr-pressure.bin" "$B/tests/dcache-conflict-writeback/dcache-conflict-writeback.bin" \
         "$B/tests/timer-mmio/timer-mmio.bin" "$B/vm/vm-pagefault-test/vm_pagefault_test.bin" "$B/tests/quick-sort/quick-sort.bin" \
         "$B/tests/memory-stress-small/memory-stress-small.bin"; do
  n=$(basename "$p" .bin)
  (cd "$ORIG" && ./build/simulator "$p" > "$S/id_$n.orig" 2>&1)
  (cd "$S/refsim_axi" && ./build/simulator "$p" > "$S/id_$n.off" 2>&1)
  (cd "$S/refsim_axi" && TTG_REC_END="$S/axi_stat.dylib" ./build/simulator "$p" > "$S/id_$n.on0" 2>&1)
  grep -av "^AXS " "$S/id_$n.on0" > "$S/id_$n.on"
  a=$(cmp -s "$S/id_$n.orig" "$S/id_$n.off" && echo same || echo DIFF)
  b=$(cmp -s "$S/id_$n.orig" "$S/id_$n.on" && echo same || echo DIFF)
  echo "$n: hooks-off $a, hooks-on(stat plugin) $b, bytes=$(wc -c < "$S/id_$n.orig")"
done
