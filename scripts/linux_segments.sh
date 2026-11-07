#!/usr/bin/env bash
# linux_segments.sh <soc_tb> <ckpt-dir> <out-dir> [cycles-per-segment=16000000]
# Linux check in parallel segments: every ckpt_special_sNN_*.gz in <ckpt-dir> (function-model `--mode special-ckpt`, one per 10M
# instructions) is restored on the RTL SoC (ckpt2image.py + ckpt2stub.py, SOC_TB_STUB) and run for <cycles> with the per-commit
# function-model check.  PASS = no [FM] mismatch/reject line and more than 1M instructions checked.  Segments overlap slightly
# (16M cycles for 10M instructions); the microarchitectural state is cold at every segment start, so cycles are NOT compared here.
# env JOBS (default 4).  Each segment ends at the cycle limit, so its log is complete (no stdout buffering issue).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
TB=$1; CK=$2; OUT=$3; CYC=${4:-16000000}; mkdir -p "$OUT"
FM=$AI_HUMA_ROOT/function-model
one() {
  ck=$1; n=$(basename "$ck" .gz | sed 's/ckpt_special_//')
  python3 "$ROOT/tools/ckpt2image.py" "$ck" "$OUT/$n.img" > /dev/null 2>&1 && python3 "$FM/tools/ckpt2stub.py" "$ck" "$OUT/$n.stub" > "$OUT/$n.stub.log" 2>&1 \
    || { echo "FAIL $n (restore files)"; return; }
  SOC_TB_STUB="$OUT/$n.stub" SOC_TB_FM=1 SOC_TB_SEMIHOST=1 perl -e 'alarm 14400; exec @ARGV' "$TB" "$OUT/$n.img" "$CYC" > "$OUT/$n.log" 2>&1
  chk=$(grep -a -o '\[FM\] [0-9]* instructions checked' "$OUT/$n.log" | grep -o '[0-9]*' | head -1); bad=$(grep -aE "^\[FM\].*(rtl=|rejects)" "$OUT/$n.log" | wc -l | tr -d ' ')
  rm -f "$OUT/$n.img"
  if [ "${chk:-0}" -gt 1000000 ] && [ "$bad" = 0 ]; then echo "PASS $n checked=$chk"; else echo "FAIL $n checked=${chk:-none} mismatches=$bad"; fi
}
export -f one; export ROOT OUT TB CYC FM
ls "$CK"/ckpt_special_s*.gz | head -13 | xargs -P "${JOBS:-4}" -I{} bash -c 'one {}' | sort | tee "$OUT/summary.txt"
echo "== $(grep -c '^PASS' "$OUT/summary.txt") PASS, $(grep -c '^FAIL' "$OUT/summary.txt") FAIL"
