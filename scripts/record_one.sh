#!/usr/bin/env bash
# Internal helper of record_all.sh: record one program with the already built recorder.
#   usage: record_one.sh <module> <prog.bin>      cap: scripts/progs.txt entry, else $GATE_CYCLES (default 30000)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cap=$(grep -v '^#' "$ROOT/scripts/progs.txt" | awk -F'|' -v p="$2" '$1 == p {print $2}')
cap=${cap:-${GATE_CYCLES:-30000}}
NOBUILD=1 CYCLES=$cap bash "$ROOT/scripts/record.sh" "$1" "$2" 2>&1 | tail -1
