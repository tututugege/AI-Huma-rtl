#!/usr/bin/env bash
# fp_synth_check.sh: bit-exact differential test of synthesizable FP units against Berkeley SoftFloat.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/fp_synth_check; rm -rf "$OUT"; mkdir -p "$OUT"
SF_INC=/home/houruyao/AI-Huma/trace-model/build/fm-55affa0-x64c1/lib/softfloat/include
SF_LIB=/home/houruyao/AI-Huma/trace-model/build/fm-55affa0-x64c1/lib/softfloat/softfloat.a
verilator --cc --exe --build -Wno-fatal -Wno-lint -Wno-style --top-module fp_synth_check_top -Mdir "$OUT" \
  -CFLAGS "-O2 -I$SF_INC" -LDFLAGS "$SF_LIB" \
  rtl/common/ttg_cfg_pkg.sv \
  rtl/backend/exu_fu/fp_arith_pkg.sv \
  rtl/backend/exu_fu/fp_misc_core.sv \
  rtl/backend/exu_fu/fp_i2f_core.sv \
  rtl/backend/exu_fu/fp_fcvt_core.sv \
  rtl/backend/exu_fu/fp_fma_core.sv \
  rtl/backend/exu_fu/fp_div_core.sv \
  tb/fp_synth/fp_synth_check_top.sv \
  tb/fp_synth/fp_synth_check.cpp \
  tb/fp_dpi/fp_dpi.cpp \
  -o fp_synth_check > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
"$OUT/fp_synth_check"
