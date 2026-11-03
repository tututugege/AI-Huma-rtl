#!/usr/bin/env bash
# Build the replay harness for one module.
#   usage: hbuild.sh <spec.io> <outdir> <rtl.sv>...
# Produces <outdir>/replay (generic replayer linked with the Verilated <mod>_tbwrap) and
# <outdir>/<mod>_fields.h (also needed by the C++ recorder).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPEC=$1; OUT=$2; shift 2
RTL=("$@")
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
MOD=$(python3 "$ROOT/harness/tools/iogen.py" "$SPEC" "$OUT" | cut -d: -f1)
TOP=${MOD}_tbwrap
# -Wall is fatal on purpose: RTL has to be lint clean to be replayed.
# --replication-limit: the generated wrapper clears out_bits with '0, which is wider than the default 8192 for big modules
verilator --cc --exe --build -j 4 --trace -Wall --replication-limit 1000000 \
  --x-assign 0 --x-initial 0 --top-module "$TOP" \
  -Mdir "$OUT/obj" -o replay \
  -CFLAGS "-std=c++17 -O1 -DTOP_HDR=\\\"V${TOP}.h\\\" -DTOP_T=V${TOP} -DFIELDS_HDR=\\\"${MOD}_fields.h\\\" -I$ROOT/harness/include -I$OUT" \
  "$OUT/${TOP}.sv" "${RTL[@]}" "$ROOT/harness/src/replay_main.cpp" >"$OUT/build.log" 2>&1 || {
  echo "BUILD FAILED ($MOD), see $OUT/build.log"; grep -E "%(Error|Warning)" "$OUT/build.log" | head -20; exit 1; }
cp "$OUT/obj/replay" "$OUT/replay"
echo "built $OUT/replay"
