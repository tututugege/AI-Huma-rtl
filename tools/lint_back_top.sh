#!/usr/bin/env bash
# Lint the back_top assembly (scripts/lint.sh only handles per-directory tops; back_top instantiates modules of other dirs).
#   usage: tools/lint_back_top.sh [top]     default back_top
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
TOP=${1:-back_top}
python3 harness/tools/svlint.py rtl/backend/back_top/*.sv
FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(bash scripts/rtl_files.sh .)
verilator --lint-only -Wall --top-module "$TOP" -Irtl/common "${FILES[@]}" 2>&1 | grep -E "^%(Warning|Error)" -A3 | head -40 || true
echo "lint done ($TOP)"
