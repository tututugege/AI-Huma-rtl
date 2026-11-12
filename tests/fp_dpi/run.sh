#!/usr/bin/env bash
# Differential test of the DPI FP datapath against the function model (rv32: XLEN=32, default).
#   usage: tests/fp_dpi/run.sh <work-dir> [cases]     env: FM_DIR (function-model with librefcpu.a built for the XLEN), XLEN
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); W=${1:?work dir}; N=${2:-200000}; mkdir -p "$W"
. "$R/scripts/env.sh"
FM=${FM_DIR:-$AI_HUMA_ROOT/function-model}; XLEN=${XLEN:-32}
clang++ -std=c++17 -O1 -DXLEN=$XLEN -I"$FM/include/api" -I"$FM/lib/softfloat/include" "$R/tests/fp_dpi/diff.cpp" "$R/tb/fp_dpi/fp_dpi.cpp" \
  "$FM/librefcpu.a" "$FM/lib/softfloat/softfloat.a" -lz -o "$W/fp_dpi_diff"
"$W/fp_dpi_diff" "$N"
