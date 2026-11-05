#!/usr/bin/env bash
# lint_chip.sh [out.txt]: whole-chip Verilator -Wall lint with soc_top as the top (lint.sh lints module directories one by one).
#   env CFG=<pkg.sv>: lint against another configuration package instead of rtl/common/ttg_cfg_pkg.sv (e.g. one written by
#   harness/tools/gen_cfg_pkg.py with -D overrides) without installing it; a DECLFILENAME warning about that file is expected.
#   Prints the warning count (0 = clean); full output in out.txt (default build/lint_chip.txt).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/lint_chip.txt}; mkdir -p "$(dirname "$OUT")"
PK=$(bash scripts/rtl_files.sh . | grep '_pkg\.sv$' | sed "s|^rtl/common/ttg_cfg_pkg.sv$|${CFG:-rtl/common/ttg_cfg_pkg.sv}|")
PR=$(find rtl/common -name 'ttg_*.sv' ! -name '*_pkg.sv' | sort)
ALL=$(bash scripts/rtl_files.sh . | grep -v '_pkg\.sv$' | grep -v '^rtl/common/')
verilator --lint-only -Wall -Wno-UNOPTFLAT --top-module soc_top -Irtl/common $PK $PR $ALL > "$OUT" 2>&1
n=$(grep -E '^%(Warning|Error)' "$OUT" | grep -v DECLFILENAME | grep -vc 'Exiting due')
echo "lint_chip: $n warnings/errors ($OUT)"; [ "$n" = 0 ]
