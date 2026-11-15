#!/usr/bin/env bash
# linux_segments_cmp.sh <soc_tb> <trace-model simulator> <ckpt-dir> <out-dir> [cycles-per-segment=4000000]
# Linux check in parallel windows, RTL against the trace-model: every ckpt_special_sNN_*.gz in <ckpt-dir> (function-model `--mode special-ckpt`) is restored
# on both the RTL SoC (ckpt2image.py + ckpt2stub.py, SOC_TB_STUB, per-commit function-model check) and the trace-model (`--mode ckpt --restore-stub`), both cold,
# and run for the same number of cycles.  PASS per segment = no [FM] mismatch/reject line and the PT / UP fingerprints are equal (scripts/align_check.py; the
# fingerprint cycles count from the end of the restore program on both sides).  The PMU intervals are NOT compared (PMU_CMP=1 does): they are cut by absolute cycle and the
# restore program (running from the non-RAM boot window at 0x0) takes ~26k cycles on the RTL but ~18k on the model, so the intervals are shifted by ~8k cycles.
# Replaces the 140M-cycle run from reset as the quick Linux gate (each window needs a few minutes, windows run in parallel); the from-reset run stays the final gate.
# The model stops at SIM_MAX_CYCLES (its `-c` is an instruction count in the ckpt mode, set high), so both sides run the same number of cycles.
# env JOBS (default 2: the RTL testbench of build_soc64_linux.sh runs 4 threads), SEGS (list like "s03 s07", default all), IV (PMU interval, default 500000), BIN (fingerprint bin, default 1000),
#     TM_ENV (trace-model environment, default LSU_PIPE_NOWD=1).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
TB=$1; TMS=$2; CK=$3; OUT=$4; CYC=${5:-4000000}; IV=${IV:-500000}; BIN=${BIN:-1000}; mkdir -p "$OUT"
FM=$AI_HUMA_ROOT/function-model
DEF=${PMU_EVENTS_DEF:-$(dirname "$(dirname "$TMS")")/include/pmu_events.def}
one() {
  ck=$1; n=$(basename "$ck" .gz | sed 's/ckpt_special_//'); d=$OUT/$n; mkdir -p "$d"
  python3 "$ROOT/tools/ckpt2image.py" "$ck" "$d/ck.img" > /dev/null 2>&1 && python3 "$FM/tools/ckpt2stub.py" "$ck" "$d/ck.stub" > "$d/stub.log" 2>&1 \
    || { echo "FAIL $n (restore files)"; return; }
  env ${TM_ENV:-LSU_PIPE_NOWD=1} SIM_MAX_CYCLES=$CYC FPR=$BIN PMU=1 PMU_OUT="$d/p" PMU_INTERVAL=$IV PMU_PCPROF=0 "$TMS" --mode ckpt -w 0 --restore-stub "$d/ck.stub" -c 1000000000 "$ck" > "$d/tm.out" 2> "$d/tm.err"
  SOC_TB_STUB="$d/ck.stub" SOC_TB_FM=1 SOC_TB_SEMIHOST=1 SOC_TB_PMU=1 SOC_TB_PMU_IV=$IV FPR=$BIN perl -e 'alarm 14400; exec @ARGV' "$TB" "$d/ck.img" "$CYC" > "$d/rtl.out" 2> "$d/rtl.err"
  chk=$(grep -a -o '\[FM\] [0-9]* instructions checked' "$d/rtl.err" | grep -o '[0-9]*' | head -1); bad=$(grep -aE "^\[FM\].*(rtl=|rejects)" "$d/rtl.err" | wc -l | tr -d ' ')
  if [ "${PMU_CMP:-0}" = 1 ]; then csv="$d/p_series.csv"; else csv=-; fi
  al=$(python3 "$ROOT/scripts/align_check.py" "$d/tm.err" "$csv" "$d/rtl.out" "$d/rtl.err" "$DEF" --bin "$BIN" --skip 1 2>&1)
  echo "$al" > "$d/align.txt"; rm -f "$d/ck.img"
  if [ "${chk:-0}" -gt 100000 ] && [ "$bad" = 0 ] && ! echo "$al" | grep -q "first difference"; then echo "PASS $n checked=$chk"; else echo "FAIL $n checked=${chk:-none} mismatches=$bad: $(echo "$al" | grep -a "first difference" | head -1 | cut -c1-110)"; fi
}
export -f one; export ROOT OUT TB TMS CYC IV BIN FM DEF PMU_CMP
if [ -n "${SEGS:-}" ]; then for s in $SEGS; do ls "$CK"/ckpt_special_${s}_*.gz; done; else ls "$CK"/ckpt_special_s*.gz; fi | xargs -P "${JOBS:-2}" -I{} bash -c 'one {}' | sort | tee "$OUT/summary.txt"
echo "== $(grep -c '^PASS' "$OUT/summary.txt") PASS, $(grep -c '^FAIL' "$OUT/summary.txt") FAIL"
