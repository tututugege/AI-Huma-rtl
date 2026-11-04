#!/usr/bin/env bash
# Netlist converter check: regenerate the SV from fadd.h/fmul.h and compare with the C++ netlist functions
# (full 37-output variant, unpruned, plus the shipped pruned 32-output modules).   usage: bash tests/fpu/run_netlist.sh [N]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-$ROOT/refsim}
N=${1:-10000000}
mkdir -p build/fpnet
for op in fadd fmul; do
  H=$REF/back-end/Exu/include/$op.h
  python3 tools/fp/netlist2sv.py "$H" fp_${op}_full build/fpnet/fp_${op}_full.sv --with-flags --no-prune >/dev/null
  for v in full net; do
    if [ $v = full ]; then SV=build/fpnet/fp_${op}_full.sv; TOP=fp_${op}_full; WF=1; else SV=tests/fpu/netlist_ref/fp_${op}_net.sv; TOP=fp_${op}_net; WF=0; fi
    D=build/fpnet/$TOP; mkdir -p $D
    verilator --cc --exe --build -j 4 -Wall -Wno-fatal --x-assign 0 --x-initial 0 -Mdir $D/obj --top-module $TOP -o tb \
      -CFLAGS "-O1 -std=c++17 -DNET_HDR=\\\"V$TOP.h\\\" -DNET_T=V$TOP -DNET_FN=${op}_io_generator -DNET_HDR2=\\\"$H\\\" -DWITH_FLAGS=$WF" \
      $SV tests/fpu/netlist_tb.cpp >$D.log 2>&1 || { tail -20 $D.log; exit 1; }
    echo -n "$op $v: "; $D/obj/tb $N
  done
done
