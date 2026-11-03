#!/usr/bin/env bash
# Coordinator check of a module branch: lint + rebuild with the MAIN repo's harness + replay named traces.
#   usage: review.sh <worktree-dir> <module> <trace-name>...      (trace names without .trc, from <worktree>/traces/<module>/)
set -uo pipefail
MAIN=$(cd "$(dirname "$0")/.." && pwd)
W=$1; MOD=$2; shift 2
cd "$W" || exit 2
bash scripts/lint.sh 2>&1 | tail -1
OUT=$W/build/review; rm -rf "$OUT"
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find rtl/common -name 'ttg_*.sv' ! -name ttg_cfg_pkg.sv | sort; find rtl -path "rtl/common" -prune -o -name '*.sv' -print | sort)
bash "$MAIN/scripts/hbuild.sh" "spec/$MOD.io" "$OUT" rtl/common/ttg_cfg_pkg.sv "${FILES[@]}" 2>&1 | tail -2
for t in "$@"; do echo -n "$t: "; "$OUT/replay" "traces/$MOD/$t.trc" | tail -1; done
