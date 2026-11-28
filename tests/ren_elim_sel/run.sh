#!/usr/bin/env bash
# Random equivalence test of rtl/backend/ren/ren_elim_sel.sv (2M vectors by default; argument: number of vectors).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$ROOT/build/test_ren_elim_sel}
mkdir -p "$OUT"
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
verilator --cc --exe --build -j "$JOBS" -Wall -Wno-DECLFILENAME \
  --top-module ren_elim_sel -Mdir "$OUT/obj" \
  "$ROOT/rtl/common/ttg_cfg_pkg.sv" \
  "$ROOT/rtl/backend/ren/ren_pkg.sv" \
  "$ROOT/rtl/common/ttg_first_set.sv" \
  "$ROOT/rtl/common/ttg_onehot_to_idx.sv" \
  "$ROOT/rtl/backend/ren/ren_elim_sel.sv" \
  "$ROOT/tests/ren_elim_sel/tb_ren_elim_sel.cpp" \
  -o test_ren_elim_sel > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
"$OUT/obj/test_ren_elim_sel" "${1:-2000000}"
