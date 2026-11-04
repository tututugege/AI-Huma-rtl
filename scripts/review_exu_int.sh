#!/usr/bin/env bash
# Coordinator review of the exu_int branch: re-record a few real programs, regenerate the random traces, rebuild with the MAIN harness, replay.
W=/Users/ruyaoh/personal/AI-Huma/rtl-wt/exu_int
M=$(cd "$(dirname "$0")/.." && pwd)
G=/Users/ruyaoh/personal/AI-Huma/trace-model/build/tests
cd "$W" || exit 2
for m in alu_bank bru_bank agu_bank sdu_bank csr_fu mul_bank div_bank; do
  for p in /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/dhrystone.bin $G/bitmanip-boundary/bitmanip-boundary.bin $G/mul-longlong/mul-longlong.bin $G/div/div.bin $G/atomic-boundary/atomic-boundary.bin; do
    [ -f "$p" ] && CYCLES=40000 bash "$W/scripts/record.sh" "$m" "$p" >/dev/null 2>&1   # the branch own script: it resolves spec/ in the branch
  done
done
[ -s traces/alu_bank/rand1.trc ] || bash tests/exu_fu/run_rand.sh >/dev/null 2>&1
for m in alu_bank bru_bank agu_bank sdu_bank csr_fu mul_bank div_bank; do
  echo "##### $m"
  names=$(ls traces/$m | sed 's/\.trc$//' | tr '\n' ' ')
  bash "$M/scripts/review.sh" "$W" "$m" $names 2>&1 | tail -12
done
