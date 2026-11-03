#!/usr/bin/env bash
# usage: [EXTRA_ENV="A=1 B=2"] run_stat.sh <refsim_dir> <plugin.dylib> <outdir>   (68 programs, AXS_N cycles cap, 4 jobs)
S=$(cd "$(dirname "$0")" && pwd)
export REF=$1 PLUG=$2 OUT=$3
mkdir -p "$OUT"; rm -f "$OUT"/*.stat
export AXS_N=${AXS_N:-300000}
run1() { p=$1; n=$(basename "$p" .bin); (cd "$REF" && env $EXTRA_ENV TTG_REC_END="$PLUG" ./build/simulator "$p" 2>/dev/null | grep -a "^AXS " > "$OUT/$n.stat"); }
export -f run1
cat "$S/axi_progs68.txt" | xargs -P${STAT_JOBS:-4} -I{} bash -c 'run1 {}'
echo finished
