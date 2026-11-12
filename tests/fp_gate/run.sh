#!/usr/bin/env bash
# Verilate isu_fp_gate (FP=1 config) and compare it with the reference's FP write-port reservation.  usage: run.sh <work-dir>
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); W=${1:?work dir}; mkdir -p "$W"
. "$R/scripts/env.sh"
python3 "$R/harness/tools/gen_cfg_pkg.py" "${SIM_SRC:-$AI_HUMA_ROOT/trace-model}" "$W/ttg_cfg_pkg.sv" -DFP=1 >/dev/null
cd "$W" && verilator --cc --exe --build -Wno-fatal -Wno-lint --top-module isu_fp_gate ttg_cfg_pkg.sv "$R/rtl/backend/isu/isu_pkg.sv" \
  "$R/rtl/common/ttg_popcount.sv" "$R/rtl/backend/isu/isu_fp_gate.sv" "$R/tests/fp_gate/main.cpp" -o gate >/dev/null
python3 "$R/tests/fp_gate/check.py" "$W/obj_dir/gate"
