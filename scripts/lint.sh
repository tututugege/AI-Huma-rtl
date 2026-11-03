#!/usr/bin/env bash
# Lint every RTL file: project style rules (svlint) + Verilator -Wall (all warnings fatal).
#   usage: lint.sh [files...]      default: every .sv under rtl/
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
if [ $# -gt 0 ]; then FILES=("$@"); else FILES=($(find rtl -name '*.sv' | sort)); fi
[ ${#FILES[@]} -gt 0 ] || { echo "no rtl files"; exit 0; }
python3 harness/tools/svlint.py "${FILES[@]}"
# the package must come first; each other file is linted as its own top (-Wall, no unused-module noise)
PKG=rtl/common/ttg_cfg_pkg.sv
for f in "${FILES[@]}"; do
  [ "$f" = "$PKG" ] && continue
  top=$(basename "$f" .sv)
  verilator --lint-only -Wall --top-module "$top" -Irtl/common $PKG $(find rtl -name '*.sv' ! -path "$f" ! -path "$PKG" | sort) "$f" 2>&1 | grep -E "^%(Warning|Error)" && { echo "LINT FAIL: $f"; exit 1; } || true
done
echo "lint ok (${#FILES[@]} files)"
