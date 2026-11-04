#!/usr/bin/env bash
# Verilator elaboration errors only (fast check after structural edits).  usage: toplint.sh [top=soc_top] [max lines=40]
cd "$(dirname "$0")/.."
FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(bash scripts/rtl_files.sh .)
verilator --lint-only -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --top-module "${1:-soc_top}" -Irtl/common "${FILES[@]}" 2>&1 | grep -a "^%Error" | head -"${2:-40}"
