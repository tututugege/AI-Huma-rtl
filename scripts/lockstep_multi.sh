#!/usr/bin/env bash
# Whole-program lock-step of MANY modules at once: one reference run per program checks every module in the same pass.
#   usage: lockstep_multi.sh <module>...           env: PROGS (file with one .bin per line; default: all gate + vm + big),
#                                                     BIG_CYCLES (default 300000: dhrystone/coremark are truncated, gate programs are shorter), JOBS (programs in parallel, default 3), NOBUILD=1
# Needs REFSIM=<tree built with the multi-plugin hook> (default: refsim_tap).  Result matrix: build/lockstep_multi.csv
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export REFSIM=${REFSIM:-$ROOT/refsim_tap}
BIG=${BIG_CYCLES:-300000}
MODS=("$@")
G=/Users/ruyaoh/personal/tututugege-trace/build
if [ -z "${NOBUILD:-}" ]; then
  # build every module's plugin once (parallel 3)
  printf '%s\n' "${MODS[@]}" | xargs -P 3 -I{} bash -c 'BUILD_ONLY=1 bash "'"$ROOT"'/scripts/lockstep.sh" {} x 2>&1 | tail -1'
fi
LIST=$ROOT/build/lockstep_multi.progs
if [ -n "${PROGS:-}" ]; then cp "$PROGS" "$LIST"; else
  { ls $G/tests/*/*.bin $G/vm/*/*.bin; for p in /tmp/big/dhrystone.bin /tmp/big/coremark.bin /Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src/baremetal/float-test/float_test.bin; do [ -f "$p" ] && echo "$p"; done; } > "$LIST"
fi
PLUG=""; for m in "${MODS[@]}"; do
  if [ -f "$ROOT/build/lock_$m/lock_$m.dylib" ]; then PLUG="$PLUG:$ROOT/build/lock_$m/lock_$m.dylib"; else echo "SKIPPED $m: no plugin (build failed, see build/lock_$m/*.log)"; fi
done; PLUG=${PLUG#:}
RES=$ROOT/build/lockstep_multi.csv; : > "$RES"
run_one() {
  p=$1; name=$(basename "$p" .bin)
  out=$( cd "$REFSIM" && TTG_REC="$PLUG" TTG_MULTI=1 TTG_REC_N=$BIG build/simulator "$p" 2>&1 | grep -aE "^LOCKSTEP|MISMATCH" )
  echo "$out" | grep -a "^LOCKSTEP" | sed "s#^#$name #" >> "$RES"
  echo "$out" | grep -a "MISMATCH" | head -3 | sed "s#^#$name #" >> "$ROOT/build/lockstep_multi.mismatch"
}
export -f run_one; export PLUG REFSIM BIG RES ROOT
: > "$ROOT/build/lockstep_multi.mismatch"
xargs -P "${JOBS:-3}" -I{} bash -c 'run_one {}' < "$LIST"
echo "== programs: $(wc -l < "$LIST"); PASS lines: $(grep -c 'LOCKSTEP PASS' "$RES"); FAIL lines: $(grep -c 'LOCKSTEP FAIL' "$RES")"
grep -a "LOCKSTEP FAIL" "$RES" | head -20
