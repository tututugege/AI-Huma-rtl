#!/usr/bin/env bash
# Verilate isu_wb_gate (FP=1 config, through wrap.sv) and compare it with the reference's per-port completion-cycle reservation (WbBusy),
# including the per-class free bits read by the select (EXP-046).  usage: run.sh <work-dir>
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); W=${1:?work dir}; mkdir -p "$W"
. "$R/scripts/env.sh"
python3 "$R/harness/tools/gen_cfg_pkg.py" "${SIM_SRC:-$AI_HUMA_ROOT/trace-model}" "$W/ttg_cfg_pkg.sv" -DFP=1 >/dev/null
NP=$(grep -E "localparam int ISSUE_WIDTH" "$W/ttg_cfg_pkg.sv" "$R/rtl/backend/isu/isu_pkg.sv" | head -1 | sed 's/.*= *\([0-9]*\);.*/\1/')
NC=$(sed -n 's/.*localparam int WB_NCLS *= *\([0-9]*\);.*/\1/p' "$R/rtl/backend/isu/isu_pkg.sv")
cd "$W" && verilator --cc --exe --build -Wno-fatal -Wno-lint --top-module wb_gate_tw -CFLAGS "-DNPORT=$NP -DNCLS=$NC" ttg_cfg_pkg.sv \
  "$R/rtl/backend/isu/isu_pkg.sv" "$R/rtl/backend/isu/isu_wb_gate.sv" "$R/tests/wb_gate/wrap.sv" "$R/tests/wb_gate/main.cpp" -o gate >/dev/null
python3 "$R/tests/wb_gate/check.py" "$W/obj_dir/gate" "$NP"
