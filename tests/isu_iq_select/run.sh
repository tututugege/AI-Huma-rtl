#!/usr/bin/env bash
# Equivalence test of rtl/backend/isu/isu_iq_select.sv against tests/isu_iq_select/isu_iq_select_ref.sv for every issue queue.
#   usage: run.sh [vectors=200000]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$ROOT/build/test_isu_iq_select}
mkdir -p "$OUT"
PKGS=(); while IFS= read -r f; do PKGS+=("$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT" | grep '_pkg\.sv$' | sed "s|^\./|$ROOT/|; s|^rtl/|$ROOT/rtl/|")
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
verilator --binary -j "$JOBS" -Wno-fatal -Wno-lint -Wno-style --top-module eq_top -GNVEC="${1:-200000}" -Mdir "$OUT/obj" \
  "${PKGS[@]}" "$ROOT/rtl/common/ttg_first_set.sv" "$ROOT/rtl/common/ttg_pick_k.sv" \
  "$ROOT/rtl/backend/isu/isu_iq_select.sv" "$ROOT/tests/isu_iq_select/isu_iq_select_ref.sv" "$ROOT/tests/isu_iq_select/eq_top.sv" \
  > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
"$OUT/obj/Veq_top"
