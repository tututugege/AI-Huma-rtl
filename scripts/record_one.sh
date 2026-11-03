#!/usr/bin/env bash
# Internal helper of record_all.sh: record one program with the already built recorder. usage: record_one.sh <module> <prog.bin>
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cap=${GATE_CYCLES:-400000}
case "$2" in /tmp/big/*) cap=300000;; esac
NOBUILD=1 CYCLES=$cap bash "$ROOT/scripts/record.sh" "$1" "$2" 2>&1 | tail -1
