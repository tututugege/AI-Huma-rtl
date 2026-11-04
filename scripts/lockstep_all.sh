#!/usr/bin/env bash
# Full-program live lock-step of one module over: all gate tests + vm tests + dhrystone/coremark/extras (capped).
#   usage: lockstep_all.sh <module>      env REFSIM (front modules need refsim_tap), BIG_CYCLES (default 4000000)
# Writes build/lockstep_<module>.log and prints one summary line per program plus a final verdict.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
MOD=$1
BIG=${BIG_CYCLES:-4000000}
LOG=$ROOT/build/lockstep_$MOD.log; : > "$LOG"
PROGS=(); while IFS= read -r p; do PROGS+=("$p"); done < <(ttg_all_progs)
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
