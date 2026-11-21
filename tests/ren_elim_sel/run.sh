#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/build/test_ren_elim_sel"
rm -rf "$OUT" && mkdir -p "$OUT"
verilator --cc --exe --build -j "$(nproc)" -Wno-fatal -Wno-lint -Wno-style \
  --top-module ren_elim_sel -Mdir "$OUT/obj" \
  "$ROOT/rtl/common/ttg_cfg_pkg.sv" \
  "$ROOT/rtl/common/ttg_first_set.sv" \
  "$ROOT/rtl/common/ttg_onehot_mux.sv" \
  "$ROOT/rtl/common/ttg_popcount.sv" \
  "$ROOT/rtl/backend/ren/ren_pkg.sv" \
  "$ROOT/rtl/backend/ren/ren_last_write.sv" \
  "$ROOT/rtl/backend/ren/ren_elim_sel.sv" \
  "$ROOT/tests/ren_elim_sel/tb_ren_elim_sel.cpp" \
  -o test_ren_elim_sel > "$OUT/build.log" 2>&1
"$OUT/obj/test_ren_elim_sel"
