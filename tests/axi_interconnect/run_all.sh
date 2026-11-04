#!/usr/bin/env bash
# Module-level lock-step of axi_interconnect over a program list (default: the 68 programs of lockstep_all.sh), at one LLC geometry.
#   usage: run_all.sh [list-file]      env  REFSIM (tap refsim), CYCLES (cap, default 300000), TTG_LLC_KB / TTG_LLC_WAYS (reference geometry),
#                                      SETS WAYS (RTL geometry macros, must match; default 4096/16), JOBS (parallel runs, default 2),
#                                      MODULE (default axi_interconnect), OUT (build dir, default build/lockta_<module>_<sets>x<ways>)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MODULE=${MODULE:-axi_interconnect}; SETS=${SETS:-4096}; WAYS=${WAYS:-16}; CYCLES=${CYCLES:-300000}; JOBS=${JOBS:-2}
LIST=${1:-}
G=/Users/ruyaoh/personal/AI-Huma/trace-model/build
if [ -z "$LIST" ]; then
  LIST=$(mktemp); ls $G/tests/*/*.bin $G/vm/*/*.bin > "$LIST"
  echo /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/dhrystone.bin >> "$LIST"; echo /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/coremark.bin >> "$LIST"
  echo /Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src/baremetal/float-test/float_test.bin >> "$LIST"
fi
export OUTDIR=${OUT:-$ROOT/build/lockta_${MODULE}_${SETS}x${WAYS}}
export VFLAGS="${VFLAGS_EXTRA:-} -Wno-fatal --assert -fno-dfg -DAXI_LLC_SETS=$SETS -DAXI_LLC_WAYS=$WAYS"
export REFSIM
first=$(head -1 "$LIST")
echo "building $MODULE ($SETS sets x $WAYS ways) ..."
BUILD_ONLY=1 JOBS=4 bash "$ROOT/scripts/lockstep_ticks_axi.sh" "$MODULE" "$first" >/dev/null 2>&1 || { echo BUILD FAILED; exit 1; }
export NOBUILD=1 ROOT MODULE CYCLES
run1() { p=$1; n=$(basename "$p" .bin); r=$(bash "$ROOT/scripts/lockstep_ticks_axi.sh" "$MODULE" "$p" "$CYCLES" 2>&1 | grep -aE "^LOCKSTEP|^  MISMATCH|unreachable" | head -3 | tr '\n' ' '); echo "$n: ${r:-NO RESULT}"; }
export -f run1
cat "$LIST" | xargs -P "$JOBS" -I{} bash -c 'run1 {}' | tee "$OUTDIR/results.txt"
echo "== PASS $(grep -c 'LOCKSTEP PASS' "$OUTDIR/results.txt") / $(wc -l < "$LIST") ($MODULE ${SETS}x${WAYS}, cap $CYCLES cycles)"
