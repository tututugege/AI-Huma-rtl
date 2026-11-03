#!/usr/bin/env bash
# Build and replay one module against one or more traces.
#   usage: replay.sh <module> [trace...]       (default traces: traces/<module>/*.trc)
# <module> needs spec/<module>.io and rtl/**/<module>.sv (+ every other rtl file as a dependency).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1; shift
cd "$ROOT"
SPEC=spec/$MOD.io; [ -f "$SPEC" ] || { echo "missing $SPEC"; exit 2; }
[ -n "$(find rtl -name "$MOD.sv" | head -1)" ] || { echo "missing rtl/**/$MOD.sv"; exit 2; }
FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(bash scripts/rtl_files.sh .)
bash scripts/hbuild.sh "$SPEC" "build/$MOD" "${FILES[@]}"
if [ $# -gt 0 ]; then TR=("$@"); else TR=(traces/$MOD/*.trc); fi
rc=0
for t in "${TR[@]}"; do
  echo "-- $t"
  "build/$MOD/replay" "$t" --vcd "build/$MOD/fail_$(basename "$t" .trc).vcd" || rc=1
done
exit $rc
