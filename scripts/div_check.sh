#!/usr/bin/env bash
# div_check.sh: structural parallel radix-4 divider (div_core STRUCT=1) vs behavioural (STRUCT=0) and C++ ref.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/div_check; rm -rf "$OUT"; mkdir -p "$OUT"
verilator --cc --exe --build -Wno-fatal -Wno-lint -Wno-style --top-module div_check_top -Mdir "$OUT" -CFLAGS -O2 \
  rtl/common/ttg_cfg_pkg.sv rtl/backend/exu_fu/fp_arith_pkg.sv rtl/backend/exu_fu/div_step.sv rtl/backend/exu_fu/div_core.sv \
  tb/div/div_check_top.sv tb/div/div_check.cpp -o div_check > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
"$OUT/div_check"
