#!/usr/bin/env bash
# Build and replay one module against one or more traces.
#   usage: replay.sh <module> [trace...]       (default traces: traces/<module>/*.trc)
# <module> needs spec/<module>.io and rtl/**/<module>.sv (+ every other rtl file as a dependency).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1; shift
cd "$ROOT"
SPEC=spec/$MOD.io; [ -f "$SPEC" ] || { echo "missing $SPEC"; exit 2; }
SRC=$(find rtl -name "$MOD.sv" | head -1); [ -n "$SRC" ] || { echo "missing rtl/**/$MOD.sv"; exit 2; }
DEPS=$(find rtl -name '*.sv' ! -name "$MOD.sv" ! -name ttg_cfg_pkg.sv | sort)
bash scripts/hbuild.sh "$SPEC" "build/$MOD" rtl/common/ttg_cfg_pkg.sv $DEPS "$SRC"
if [ $# -gt 0 ]; then TR=("$@"); else TR=(traces/$MOD/*.trc); fi
rc=0
for t in "${TR[@]}"; do
  echo "-- $t"
  "build/$MOD/replay" "$t" --vcd "build/$MOD/fail_$(basename "$t" .trc).vcd" || rc=1
done
exit $rc
