#!/usr/bin/env bash
# mul_check.sh: the structural Wallace-tree multiplier (mul_core STRUCT=1) against the behavioural one and a C++ reference, random + corner operands.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/mul_check; rm -rf "$OUT"; mkdir -p "$OUT"
verilator --cc --exe --build -Wno-fatal -Wno-lint -Wno-style --top-module mul_check_top -Mdir "$OUT" -CFLAGS -O2 \
  rtl/common/ttg_cfg_pkg.sv rtl/backend/exu_fu/mul_core.sv tb/mul/mul_check_top.sv tb/mul/mul_check.cpp -o mul_check > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
"$OUT/mul_check"
