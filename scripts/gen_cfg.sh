#!/usr/bin/env bash
# Regenerate rtl/common/ttg_cfg_pkg.sv from the reference simulator (default: baseline-sim).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIM=${SIM_SRC:-/Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src}
python3 "$ROOT/harness/tools/gen_cfg_pkg.py" "$SIM" "$ROOT/rtl/common/ttg_cfg_pkg.sv" "$@"
