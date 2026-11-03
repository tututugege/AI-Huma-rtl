#!/usr/bin/env bash
# Tier 2: run every mutant of tests/bpu/mutants.txt against the random trace(s) with the trace replayer (spec/bpu.io, top level).
#   usage: run_mut_replay.sh <trace-name>... (traces/bpu/<name>.trc, see run_rand.sh)      env JOBS (default 3)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
JOBS=${JOBS:-3}
TR=("$@")
run() {
  line=$1
  spec=${line%%@@*}; rest=${line#*@@}; file=${rest%%@@*}; rest=${rest#*@@}; old=${rest%%@@*}; new=${rest#*@@}
  r=$(bash "$ROOT/scripts/mutcheck.sh" "$ROOT" bpu "$file" "$old" "$new" "${TR[@]}" 2>&1)
  if echo "$r" | grep -q "PATTERN\|not found"; then v="PATTERN?"
  elif echo "$r" | grep -q "FAIL\|MISMATCH"; then v="CAUGHT   "
  elif echo "$r" | grep -q "PASS"; then v="SURVIVED "
  else v="NOVERDICT"; fi
  echo "$v [$spec] $file: $old -> $new :: $(echo "$r" | grep -a 'MISMATCH' | head -1)"
}
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
  run "$line" &
done < "$ROOT/tests/bpu/mutants.txt"
wait
