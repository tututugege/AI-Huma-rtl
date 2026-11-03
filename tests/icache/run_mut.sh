#!/usr/bin/env bash
# Run every mutant of tests/icache/mutants.txt (JOBS in parallel, default 2): REAL = whole-program lock-step on a few programs, RANDOM = random trace replay.
#   usage: run_mut.sh [mutant-file]        env REFSIM, JOBS, PROGS, CYC
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIST=${1:-$ROOT/tests/icache/mutants.txt}; JOBS=${JOBS:-2}
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
  f=${line%%@@*}; rest=${line#*@@}; old=${rest%%@@*}; new=${rest#*@@}
  bash "$ROOT/tests/icache/mut.sh" "$f" "$old" "$new" &
done < "$LIST"
wait
