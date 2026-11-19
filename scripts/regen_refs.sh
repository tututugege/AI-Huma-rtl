#!/usr/bin/env bash
# regen_refs.sh <trace-model simulator> [note]: rewrite scripts/ref_cycles.txt and scripts/ref_cycles_nopf.txt (PF_ENABLE=0) with the
# model's cycles on the gate programs (scripts/tm_cycles.sh), keeping the comment header and appending one line: date, model
# revision (git of the simulator's tree), note. Use it whenever the model's default configuration (= the RTL's) changes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
SIMB=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); NOTE=${2:-}
REV=$(git -C "$(dirname "$SIMB")" log -1 --format=%h 2>/dev/null || echo unknown)
for t in ref_cycles.txt:"" ref_cycles_nopf.txt:PF_ENABLE=0; do
  f=${t%%:*}; e=${t#*:}; tmp=$(mktemp)
  env $e bash "$ROOT/scripts/tm_cycles.sh" "$SIMB" "$tmp"
  if grep -q "FAIL\|MISSING" "$tmp"; then grep "FAIL\|MISSING" "$tmp" >&2; echo "not written: $f" >&2; exit 1; fi
  { grep '^#' "$ROOT/scripts/$f"; echo "# $(date +%F) regen_refs.sh: trace-model $REV ${e:-default}${NOTE:+; $NOTE}"; cat "$tmp"; } > "$ROOT/scripts/$f.new"
  mv "$ROOT/scripts/$f.new" "$ROOT/scripts/$f"; echo "wrote scripts/$f ($(grep -vc '^#' "$ROOT/scripts/$f") programs)"
done
