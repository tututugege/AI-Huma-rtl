#!/usr/bin/env bash
# linux_gate.sh <soc_tb> <trace-model simulator> <linux image> [cycles=140000000] [out-dir]
# Linux boot from reset: the RTL (per-commit function-model check, SOC_TB_FM) and the trace-model run the same image for the same number of
# cycles.  PASS needs all of
#   1. the function-model check: no [FM] mismatch / reject line (register values, store address and data, device reads, interrupts);
#   2. the PMU numbers printed every IV cycles are identical, trace-model against RTL (scripts/align_check.py, tier-1 events, every interval);
#   3. the console shows "login:" (NEED_LOGIN=0 skips it for a short run).
# env IV (PMU interval in cycles, default 500000), NEED_LOGIN (default 1), TM_ENV (extra environment of the trace-model, default empty: the model default = the RTL configuration).
# The model needs SIM_MAX_CYCLES to stop; the trace-model is built with the same XLEN/RVC/FP as the RTL image.
# Build the rv64 testbench for this gate with scripts/build_soc64_linux.sh (4 simulation threads by default: a single-threaded build needs 2-3x the time
# for the 140M cycles).  The trace-model must have the rv64 stale-value path (MsData, EXP-040) and the RTL the MDP / history-symbol fixes, else the PMU series differ.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
SOC=$1; TMS=$2; IMG=$3; CYC=${4:-140000000}; OUT=${5:-$(mktemp -d)}; IV=${IV:-500000}; mkdir -p "$OUT"
DEF=${PMU_EVENTS_DEF:-$(dirname "$(dirname "$TMS")")/include/pmu_events.def}
env ${TM_ENV:-} SIM_MAX_CYCLES=$CYC PMU=1 PMU_OUT="$OUT/p" PMU_INTERVAL=$IV PMU_PCPROF=0 "$TMS" "$IMG" > "$OUT/tm.out" 2> "$OUT/tm.err" &
TMPID=$!
SOC_TB_FM=1 SOC_TB_SEMIHOST=1 SOC_TB_PMU=1 SOC_TB_PMU_IV=$IV "$SOC" "$IMG" "$CYC" > "$OUT/rtl.out" 2> "$OUT/rtl.err"
wait $TMPID
fail=0
chk=$(grep -a -o '\[FM\] [0-9]* instructions checked.*' "$OUT/rtl.err" | tail -1)
bad=$(grep -aE "^\[FM\].*(rtl=|rejects|device load #|store address|MISMATCH)" "$OUT/rtl.err" | head -3)
if [ -n "$chk" ] && [ -z "$bad" ]; then echo "PASS function-model check: $chk"; else echo "FAIL function-model check: ${bad:-no [FM] summary}"; fail=1; fi
pmu=$(python3 "$ROOT/scripts/align_check.py" "$OUT/tm.err" "$OUT/p_series.csv" "$OUT/rtl.out" "$OUT/rtl.err" "$DEF" | grep -a "^PMU series")
case "$pmu" in *"tier-1 events equal"*) echo "PASS $pmu";; *) echo "FAIL $pmu"; fail=1;; esac
if [ "${NEED_LOGIN:-1}" = 1 ]; then
  if grep -aq "login:" "$OUT/rtl.out"; then echo "PASS console reached login:"; else echo "FAIL console never reached login:"; fail=1; fi
fi
echo "logs: $OUT"; [ $fail = 0 ] && echo "LINUX GATE PASS" || echo "LINUX GATE FAIL"; exit $fail
