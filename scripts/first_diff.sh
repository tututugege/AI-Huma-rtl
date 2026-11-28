#!/usr/bin/env bash
# usage: TM=<trace-model simulator> scripts/first_diff.sh <prog.bin> <cycles>   -- runs trace-model and the RTL closed loop and prints the first divergence
#   TM must be given: the env.sh default ($AI_HUMA_ROOT/trace-model/build/simulator) is often a different branch than this RTL
#   (e.g. a trace-model-<exp> worktree next to a main checkout), and a wrong model shows up as a fake timing difference.
set -euo pipefail
[ -n "${TM:-}" ] || { echo "first_diff.sh: set TM=<trace-model simulator built from the tree that matches this RTL>" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
[ -x "$TM" ] || { echo "first_diff.sh: TM=$TM is not an executable" >&2; exit 2; }
echo "TM: $TM ($(git -C "$(dirname "$TM")" log -1 --format='%h %s' 2>/dev/null | cut -c1-60))"
P=$1; CYC=${2:-20000}; D=$(mktemp -d)
TB_TRACE_COMMIT=1 SIM_MAX_CYCLES=$CYC "$TM" "$P" 2> "$D/tm.log" > /dev/null || true
SOC_TB_COMMIT=1 "${CORE_TB:-${SOC_TB:-$ROOT/build/core/obj/core_tb}}" "$P" "$CYC" 2> "$D/rtl.log" > /dev/null || true
python3 "$ROOT/scripts/first_diff.py" "$D/tm.log" "$D/rtl.log" "${CTX:-5}"; rc=$?
echo "logs: $D"; exit $rc
