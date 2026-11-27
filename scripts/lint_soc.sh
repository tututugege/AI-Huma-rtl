#!/usr/bin/env bash
# lint_soc.sh [out.txt]: whole-chip Verilator -Wall lint with chip_top as the top.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/lint_soc.txt}; mkdir -p "$(dirname "$OUT")"
PK=$(bash scripts/rtl_files.sh . | grep '_pkg\.sv$' | sed "s|^rtl/common/ttg_cfg_pkg.sv$|${CFG:-rtl/common/ttg_cfg_pkg.sv}|")
PR=$(find rtl/common -name 'ttg_*.sv' ! -name '*_pkg.sv' | sort)
ALL=$(bash scripts/rtl_files.sh . | grep -v '_pkg\.sv$' | grep -v '^rtl/common/')
verilator --lint-only -Wall -Wno-UNOPTFLAT --top-module chip_top -Irtl/common $PK $PR $ALL > "$OUT" 2>&1
n=$(grep -E '^%(Warning|Error)' "$OUT" | grep -v DECLFILENAME | grep -vc 'Exiting due')
echo "lint_soc: $n warnings/errors ($OUT)"; [ "$n" = 0 ]
