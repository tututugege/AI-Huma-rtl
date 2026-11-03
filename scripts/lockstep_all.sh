#!/usr/bin/env bash
# Full-program live lock-step of one module over: all gate tests + vm tests + dhrystone/coremark/extras (capped).
#   usage: lockstep_all.sh <module>      env REFSIM (front modules need refsim_tap), BIG_CYCLES (default 4000000)
# Writes build/lockstep_<module>.log and prints one summary line per program plus a final verdict.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1
BIG=${BIG_CYCLES:-4000000}
LOG=$ROOT/build/lockstep_$MOD.log; : > "$LOG"
G=/Users/ruyaoh/personal/tututugege-trace/build
PROGS=(); for p in $G/tests/*/*.bin; do PROGS+=("$p"); done
for p in $G/vm/*/*.bin /tmp/big/dhrystone.bin /tmp/big/coremark.bin /Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src/baremetal/float-test/float_test.bin; do [ -f "$p" ] && PROGS+=("$p"); done
first=1; pass=0; fail=0
for p in "${PROGS[@]}"; do
  name=$(basename "$p" .bin)
  if [ $first = 1 ]; then out=$(BIG_UNUSED=1 TTG_REC_N=$BIG bash "$ROOT/scripts/lockstep.sh" "$MOD" "$p" "$BIG" 2>&1); first=0
  else out=$(NOBUILD=1 bash "$ROOT/scripts/lockstep.sh" "$MOD" "$p" "$BIG" 2>&1); fi
  line=$(echo "$out" | grep -aE "LOCKSTEP|BUILD FAILED" | head -1)
  echo "$name: ${line:-NO RESULT}" >> "$LOG"
  case "$line" in *"LOCKSTEP PASS"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "$out" | head -14 >> "$LOG";; esac
done
echo "== $MOD: $pass passed, $fail failed (of ${#PROGS[@]} programs)" | tee -a "$LOG"
