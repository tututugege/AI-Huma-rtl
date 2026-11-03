#!/usr/bin/env bash
# Run every mutant of tests/bpu/mutants.txt (3 in parallel) against the whole-program lock-step.
#   usage: run_mut.sh [program.bin] [cycles] [mutant-lines-file]       env REFSIM, JOBS
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROG=${1:-/tmp/big/dhrystone.bin}; CYC=${2:-300000}; LIST=${3:-$ROOT/tests/bpu/mutants.txt}
export ROOT PROG CYC
grep -v '^#' "$LIST" | grep -v '^$' | tr '\n' '\0' | xargs -0 -P "${JOBS:-3}" -I{} bash -c '
  line=$1
  spec=${line%%@@*}; rest=${line#*@@}; file=${rest%%@@*}; rest=${rest#*@@}; old=${rest%%@@*}; new=${rest#*@@}
  bash "$ROOT/tests/bpu/mut.sh" "$spec" "$file" "$old" "$new" "$PROG" "$CYC"' _ {}
