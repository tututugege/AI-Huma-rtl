#!/usr/bin/env bash
# Build the constrained-random fpu trace generator against the reference FPUSoftfloat and write traces/fpu/rand*.trc.
#   usage: bash tests/fpu/run_rand.sh [cycles per trace (default 300000)]    (needs build/fpu/fpu_fields.h: run replay.sh once)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
CYC=${1:-300000}
python3 harness/tools/iogen.py spec/fpu.io build/fpu >/dev/null
mkdir -p build/tb traces/fpu
# no -DNDEBUG: the reference's Assert()s stay on
bash tests/fpu/build_tool.sh tests/fpu/rand_trace.cpp build/tb/fpu_rand -Ibuild/fpu
i=0
for p in 0 1 2 3; do
  for s in 1 2; do
    build/tb/fpu_rand traces/fpu/rand_p${p}_s${s}.trc $((p * 10 + s)) $CYC $p
  done
done
