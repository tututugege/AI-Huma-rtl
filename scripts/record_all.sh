#!/usr/bin/env bash
# Record a module against the standard program set (all gate tests + dhrystone/coremark), JOBS in parallel.
#   usage: record_all.sh <module>        env GATE_CYCLES (default 400000), JOBS (default 4)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1
GATE=/Users/ruyaoh/personal/tututugege-trace/build/tests
mkdir -p "$ROOT/build"
LST=$ROOT/build/progs.$MOD.lst
{ ls $GATE/*/*.bin; grep -v '^#' "$ROOT/scripts/progs.txt" | cut -d'|' -f1; } | while read -r p; do [ -f "$p" ] && echo "$p"; done > "$LST" || true
bash "$ROOT/scripts/record.sh" "$MOD" >/dev/null          # generate + compile the recorder once
rm -f "$ROOT/traces/$MOD"/*.trc
xargs -P "${JOBS:-4}" -I{} bash "$ROOT/scripts/record_one.sh" "$MOD" {} < "$LST"
echo "traces in $ROOT/traces/$MOD: $(ls "$ROOT/traces/$MOD" | wc -l) programs"
