#!/usr/bin/env bash
# Lint every RTL file: project style rules (svlint) + Verilator -Wall (all warnings fatal).
#   usage: lint.sh [files...]      default: every .sv under rtl/
set -euo pipefail
TOOLS=$(cd "$(dirname "$0")" && pwd)
ROOT=${LINT_ROOT:-$(cd "$TOOLS/.." && pwd)}   # LINT_ROOT: lint another checkout (coordinator review)
cd "$ROOT"
if [ $# -gt 0 ]; then FILES=("$@"); else FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(bash "$TOOLS/rtl_files.sh" .); fi
[ ${#FILES[@]} -gt 0 ] || { echo "no rtl files"; exit 0; }
python3 "$TOOLS/../harness/tools/svlint.py" "${FILES[@]}"
# the package must come first; each other file is linted as its own top (-Wall, no unused-module noise)
PKG=rtl/common/ttg_cfg_pkg.sv
for f in "${FILES[@]}"; do
  [ "$f" = "$PKG" ] && continue
  top=$(basename "$f" .sv)
  out=$(verilator --lint-only -Wall --top-module "$top" -Irtl/common $PKG $(bash "$TOOLS/rtl_files.sh" . | grep -v -x -e "$f" -e "$PKG") "$f" 2>&1 || true)
  if echo "$out" | grep -qE "^%(Warning|Error)"; then echo "$out" | grep -E "^%(Warning|Error)" -A3 | head -20; echo "LINT FAIL: $f"; exit 1; fi
done
echo "lint ok (${#FILES[@]} files)"
