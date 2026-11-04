#!/usr/bin/env bash
# usage: scripts/first_diff.sh <prog.bin> <cycles>   -- runs trace-model and the RTL closed loop and prints the first divergence
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
P=$1; CYC=${2:-20000}; D=$(mktemp -d)
TB_TRACE_COMMIT=1 SIM_MAX_CYCLES=$CYC "$TM" "$P" 2> "$D/tm.log" > /dev/null || true
SOC_TB_COMMIT=1 "${SOC_TB:-$ROOT/build/soc/obj/soc_tb}" "$P" "$CYC" 2> "$D/rtl.log" > /dev/null || true
python3 "$ROOT/scripts/first_diff.py" "$D/tm.log" "$D/rtl.log" "${CTX:-5}"; rc=$?
echo "logs: $D"; exit $rc
