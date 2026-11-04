#!/usr/bin/env bash
# Closed-loop check: run programs on the RTL SoC (tb/soc, Verilated core_top + mem_top) and compare the cycle count with the
# reference simulator's (scripts/ref_cycles.txt: "<cycles> <dir>/<file>.bin", measured with refsim_tap).
#   usage: soc_smoke.sh [max_ref_cycles=20000]      env JOBS (default 4), MINC (skip programs shorter than this)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
MAXC=${1:-20000}; MINC=${MINC:-0}
TB=$ROOT/build/soc/obj/soc_tb
[ -x "$TB" ] || { echo "build first: bash tb/soc/build.sh"; exit 2; }
run_one() {
  ref=$1; rel=$2
  p=$(grep -F "/$rel" "$ROOT/build/soc_progs.txt" | head -1)
  [ -n "$p" ] || { echo "SKIP $rel (not found)"; return; }
  out=$(perl -e 'alarm 2400; exec @ARGV' "$TB" "$p" $((ref * 2 + 100)) 2>&1 | grep -a "sim-time" | head -1)
  got=$(echo "$out" | sed 's/.*= \([0-9]*\),.*/\1/')
  if [ "$got" = "$ref" ] && ! echo "$out" | grep -q "NO EBREAK"; then echo "PASS $rel $ref"; else echo "FAIL $rel ref=$ref rtl=${got:-none} $out"; fi
}
export -f run_one; export ROOT TB
{ ls "$TTG_PROGS"/tests/*/*.bin "$TTG_PROGS"/vm/*/*.bin; echo "$TTG_BIG/dhrystone.bin"; echo "$TTG_BIG/coremark.bin"; } > "$ROOT/build/soc_progs.txt"
awk -v m="$MAXC" -v n="$MINC" '$1<=m && $1>=n' "$ROOT/scripts/ref_cycles.txt" | xargs -P "${JOBS:-4}" -L1 bash -c 'run_one $0 $1' | tee "$ROOT/build/soc_smoke.log"
echo "== PASS: $(grep -c '^PASS' "$ROOT/build/soc_smoke.log")  FAIL: $(grep -c '^FAIL' "$ROOT/build/soc_smoke.log")"
