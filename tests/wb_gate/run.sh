#!/usr/bin/env bash
# Verilate isu_wb_gate (FP=1 config) and compare it with the reference's per-port completion-cycle reservation (WbBusy).  usage: run.sh <work-dir>
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); W=${1:?work dir}; mkdir -p "$W"
. "$R/scripts/env.sh"
python3 "$R/harness/tools/gen_cfg_pkg.py" "${SIM_SRC:-$AI_HUMA_ROOT/trace-model}" "$W/ttg_cfg_pkg.sv" -DFP=1 >/dev/null
NP=$(grep -E "localparam int ISSUE_WIDTH" "$W/ttg_cfg_pkg.sv" "$R/rtl/backend/isu/isu_pkg.sv" | head -1 | sed 's/.*= *\([0-9]*\);.*/\1/')
cd "$W" && verilator --cc --exe --build -Wno-fatal -Wno-lint --top-module isu_wb_gate -CFLAGS -DNPORT=$NP ttg_cfg_pkg.sv "$R/rtl/backend/isu/isu_pkg.sv" \
  "$R/rtl/backend/isu/isu_wb_gate.sv" "$R/tests/wb_gate/main.cpp" -o gate >/dev/null
g() { sed -n "s/.*localparam int $1 *= *\([0-9]*\);.*/\1/p" "$W/ttg_cfg_pkg.sv" | head -1; }
D=$(g DIV_MAX_LATENCY); F=$(g FP_FSQRT_D_LAT); MAXOFF=$(( (D > F ? D : F) + 1 ))   # WB_OFF_MAX of isu_pkg
python3 "$R/tests/wb_gate/check.py" "$W/obj_dir/gate" "$NP" "$MAXOFF"
