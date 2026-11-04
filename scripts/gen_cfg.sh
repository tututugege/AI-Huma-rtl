#!/usr/bin/env bash
# Regenerate rtl/common/ttg_cfg_pkg.sv from trace-model/include/config.h (the single source of the core parameters).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
SIM=${SIM_SRC:-$AI_HUMA_ROOT/trace-model}
python3 "$ROOT/harness/tools/gen_cfg_pkg.py" "$SIM" "$ROOT/rtl/common/ttg_cfg_pkg.sv" "$@"
