#!/usr/bin/env bash
# build_progs.sh: build the gate programs (rv64ima cpu-tests + the trace-model extras, no C instructions) into $TTG_PROGS/tests
# (env.sh default build/progs) with trace-model's scripts/build_tests.sh (Homebrew LLVM). TM_SRC: the trace-model tree whose
# baremetal / tests/extra are used (default $AI_HUMA_ROOT/trace-model).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
TM_SRC=${TM_SRC:-$AI_HUMA_ROOT/trace-model}
[ -f "$TM_SRC/scripts/build_tests.sh" ] || { echo "no $TM_SRC/scripts/build_tests.sh (set TM_SRC to a trace-model tree)" >&2; exit 1; }
mkdir -p "$TTG_PROGS/tests"
bash "$TM_SRC/scripts/build_tests.sh" "$TM_SRC" "$TTG_PROGS/tests" > "$TTG_PROGS/build.log" 2>&1
extras=$(ls "$TM_SRC/tests/extra"/*.c | xargs -n1 basename | sed 's/\.c$//' | grep -v "^fdoff$")
bash "$TM_SRC/scripts/build_tests.sh" "$TM_SRC" "$TTG_PROGS/tests" $extras >> "$TTG_PROGS/build.log" 2>&1
echo "$(ls "$TTG_PROGS"/tests/*/*.bin | wc -l | tr -d ' ') programs in $TTG_PROGS/tests"
