#!/usr/bin/env bash
# Differential test of the combinational FPU datapath against softfloat.  usage: bash tests/fpu/run_compute.sh [N per class] [seed]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/AI-Huma/rtl/refsim}
N=${1:-2000000}; SEED=${2:-1}
D=build/fpu_compute; mkdir -p $D
INC=(); for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end; do INC+=("-I$REF/$d"); done
FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(bash scripts/rtl_files.sh . | grep -E "rtl/common|rtl/backend/fpu/")
verilator --cc --exe --build -j 4 -Wno-fatal --x-assign 0 --x-initial 0 -Mdir $D/obj --top-module fpu_exec_tb -o tb \
  -CFLAGS "-O1 -std=c++2a -w ${INC[*]} -Itests/fpu" -LDFLAGS "$REF/libs/softfloat.a" \
  "${FILES[@]}" tests/fpu/fpu_exec_tb.sv tests/fpu/compute_tb.cpp >$D/build.log 2>&1 || { tail -30 $D/build.log; exit 1; }
$D/obj/tb $N $SEED
