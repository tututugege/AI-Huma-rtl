#!/usr/bin/env bash
# Verilate idu_ctrl_decode with the FP=1 configuration and check the F/D decode against the model's rules.
#   usage: tests/fp_decode/run.sh <work-dir>      (the FP=1 config is generated into it: scripts/gen_cfg.sh -DFP=1 on SIM_SRC)
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); W=${1:?work dir}; mkdir -p "$W"
cp "$R/rtl/common/ttg_cfg_pkg.sv" "$W/ttg_cfg_pkg.committed.sv"
. "$R/scripts/env.sh"
python3 "$R/harness/tools/gen_cfg_pkg.py" "${SIM_SRC:-$AI_HUMA_ROOT/trace-model}" "$W/ttg_cfg_pkg.sv" -DFP=1 >/dev/null
cd "$W" && verilator --cc --exe --build -Wno-fatal -Wno-lint --top-module idu_ctrl_decode ttg_cfg_pkg.sv \
  "$R/rtl/common/ttg_onehot_mux.sv" "$R/rtl/backend/idu/idu_ctrl_decode.sv" "$R/tests/fp_decode/main.cpp" -o dec >/dev/null
python3 "$R/tests/fp_decode/check.py" "$W/obj_dir/dec"
