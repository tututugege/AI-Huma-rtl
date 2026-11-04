#!/usr/bin/env bash
# Record a module against the standard program set: all gate tests + scripts/progs.txt, JOBS in parallel.
#   usage: record_all.sh <module>
#   env  GATE_CYCLES (default 30000), JOBS (default 2), EXTRA_ONLY=1 (record only scripts/progs.txt entries and keep existing traces), SKIP_EXISTING=1
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
MOD=$1
GATE=$TTG_PROGS/tests
mkdir -p "$ROOT/build"
LST=$ROOT/build/progs.$MOD.lst
{ [ -n "${EXTRA_ONLY:-}" ] || ls $GATE/*/*.bin; ttg_resolve_list "$ROOT/scripts/progs.txt" | cut -d'|' -f1; } | while read -r p; do [ -f "$p" ] && echo "$p"; done > "$LST" || true
bash "$ROOT/scripts/record.sh" "$MOD" >/dev/null          # generate + compile the recorder once
# remove only the traces of the programs about to be re-recorded; generated traces (rand_*, exh_*, ...) are kept
[ -n "${EXTRA_ONLY:-}" ] || while read -r p; do rm -f "$ROOT/traces/$MOD/$(basename "$p" .bin).trc"; done < "$LST"
xargs -P "${JOBS:-2}" -I{} bash "$ROOT/scripts/record_one.sh" "$MOD" {} < "$LST"
echo "traces in $ROOT/traces/$MOD: $(ls "$ROOT/traces/$MOD" | wc -l) programs"
