#!/usr/bin/env bash
# Whole-program fast-tick lock-step of one module over the standard program set (gate tests + vm tests + dhrystone/coremark/float).
#   usage: lockstep_ticks_all.sh <module>      env: REFSIM (memsys-tap refsim), BIG_CYCLES (default 300000 CPU cycles; shorter programs just end),
#                                                   JOBS (default 3), NOBUILD=1, PROGS (file listing .bin paths), TTG_MUT (mutant id for mutation runs)
# Result lines: build/lockt_all_<module>.csv ("<prog> LOCKSTEP PASS|FAIL ...").  Build the plugin once with `BUILD_ONLY=1 lockstep_ticks.sh <module> x`.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1
export REFSIM=${REFSIM:?set REFSIM}
BIG=${BIG_CYCLES:-300000}
G=/Users/ruyaoh/personal/AI-Huma/trace-model/build
if [ -z "${NOBUILD:-}" ]; then BUILD_ONLY=1 VFLAGS="${VFLAGS:---assert}" bash "$ROOT/scripts/lockstep_ticks.sh" "$MOD" x 2>&1 | tail -1; fi
DYL=$ROOT/build/lockt_$MOD/lock_${MOD}.dylib
[ -f "$DYL" ] || { echo "no plugin $DYL"; exit 2; }
LIST=$ROOT/build/lockt_all_$MOD.progs
if [ -n "${PROGS:-}" ]; then cp "$PROGS" "$LIST"; else
  { ls $G/tests/*/*.bin $G/vm/*/*.bin; for p in /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/dhrystone.bin /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/coremark.bin /Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src/baremetal/float-test/float_test.bin; do [ -f "$p" ] && echo "$p"; done; } > "$LIST"
fi
RES=$ROOT/build/lockt_all_$MOD.csv; : > "$RES"
run_one() {
  p=$1; name=$(basename "$p" .bin)
  out=$( cd "$REFSIM" && TTG_REC_END="$DYL" TTG_REC_N=$((BIG * 16)) build/simulator "$p" 2>&1 | grep -aE "^LOCKSTEP|MISMATCH|%Error" | head -4 | tr '\n' ' ' )
  echo "$name $out" >> "$RES"
}
export -f run_one; export REFSIM BIG RES DYL
xargs -P "${JOBS:-3}" -I{} bash -c 'run_one {}' < "$LIST"
echo "== programs: $(wc -l < "$LIST" | tr -d ' '); PASS: $(grep -c 'LOCKSTEP PASS' "$RES" | tr -d ' '); FAIL: $(grep -c 'LOCKSTEP FAIL' "$RES"); no-result: $(grep -vc 'LOCKSTEP' "$RES"); with %Error (assertion stop): $(grep -c '%Error' "$RES")"
grep -v "LOCKSTEP PASS" "$RES" | head -20; grep "%Error" "$RES" | head -5
