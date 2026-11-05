#!/usr/bin/env bash
# fm_gate.sh <soc_tb> <outdir>: every program in scripts/ref_cycles.txt on the RTL SoC with the per-commit function-model check.
#   build the testbench with  SOC_FM=1 SOC_OUT=<abs dir> bash tb/soc/build.sh   (SOC_OUT must be an absolute path)
#   PASS = ebreak reached within 3x(ref)+20000 cycles and no [FM] mismatch line ("rtl=" / "rejects"); the
#   "[FM] N instructions checked" summary line is not a mismatch. Writes <outdir>/<name>.log and <outdir>/summary.txt
#   ("PASS name cycles committed ref=..."). Cycles are not compared here: compare summary.txt with ref_cycles.txt / trace-model.
#   env JOBS (default 6)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
TB=$1; OUT=$2; mkdir -p "$OUT"
{ ls "$TTG_PROGS"/tests/*/*.bin "$TTG_PROGS"/vm/*/*.bin; echo "$TTG_BIG/dhrystone.bin"; echo "$TTG_BIG/coremark.bin"; } > "$OUT/progs.txt"
one() {
  ref=$1; rel=$2; n=$(basename "$rel" .bin)
  p=$(grep -F "/$rel" "$OUT/progs.txt" | head -1); [ -n "$p" ] || { echo "SKIP $n"; return; }
  SOC_TB_FM=1 perl -e 'alarm 5400; exec @ARGV' "$TB" "$p" $((ref * 3 + 20000)) > "$OUT/$n.log" 2>&1
  l=$(grep -a "sim-time" "$OUT/$n.log" | head -1); fm=$(grep -aE "^\[FM\].*(rtl=|rejects)" "$OUT/$n.log" | wc -l | tr -d " ")
  cyc=$(echo "$l" | sed -n 's/.*= \([0-9]*\), committed= \([0-9]*\).*/\1 \2/p')
  if [ -n "$cyc" ] && [ "$fm" = 0 ] && ! echo "$l" | grep -q "NO EBREAK"; then echo "PASS $n $cyc ref=$ref"; else echo "FAIL $n fm=$fm $l"; fi
}
export -f one; export OUT TB
grep -v '^#' "$ROOT/scripts/ref_cycles.txt" | grep . | xargs -P "${JOBS:-6}" -L1 bash -c 'one $0 $1' | sort > "$OUT/summary.txt"
echo "== $(basename "$OUT"): PASS $(grep -c '^PASS' "$OUT/summary.txt")  FAIL $(grep -c '^FAIL' "$OUT/summary.txt")  SKIP $(grep -c '^SKIP' "$OUT/summary.txt")"
awk '$1=="PASS" { split($5, r, "="); if ($3 != r[2]) d++ } END { print "cycles different from ref_cycles.txt: " d+0 }' "$OUT/summary.txt"
