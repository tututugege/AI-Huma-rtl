#!/usr/bin/env bash
# Live lock-step co-simulation of one module's RTL against the reference simulator, over a WHOLE program (no trace files).
#   usage: lockstep.sh <module> <program.bin> [cycles]        env REFSIM (default: ./refsim), ROOT-relative spec/<module>.io
# The Verilated RTL is compiled into a plugin loaded by the instrumented reference simulator; every cycle the reference's
# module-boundary values drive the RTL and every RTL output is compared at once. Prints "LOCKSTEP PASS <mod>: N cycles
# compared" or the first mismatch (cycle, field, values, inputs) and exits 1.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1; PROG=${2:-}; CYC=${3:-}
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}
SPEC=$ROOT/spec/$MOD.io; [ -f "$SPEC" ] || { echo "missing $SPEC"; exit 2; }
OUT=$ROOT/build/lock_$MOD; mkdir -p "$OUT"
if [ -z "${NOBUILD:-}" ]; then
  python3 "$ROOT/harness/tools/iogen.py" "$SPEC" "$OUT" >/dev/null
  FILES=(); while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT")
  TOP=${MOD}_tbwrap
  ( cd "$OUT" && verilator --cc --build -j 4 -Wall --x-assign 0 --x-initial 0 --top-module "$TOP" -Mdir obj \
      -CFLAGS "-O2 -fPIC" "$OUT/${TOP}.sv" "${FILES[@]}" >build.log 2>&1 ) || { echo "RTL BUILD FAILED ($MOD), see $OUT/build.log"; grep -E "%(Error|Warning)" "$OUT/build.log" | head -10; exit 1; }
  VINC=$(verilator --getenv VERILATOR_ROOT)/include
  INC=""
  for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
           MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end \
           axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
           axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC="$INC -I$REF/$d"; done
  clang++ -std=c++2a -O2 -w -fPIC -shared -undefined dynamic_lookup -DNDEBUG $INC -I"$VINC" -I"$VINC/vltstd" -I"$OUT/obj" \
    -I"$ROOT/harness/include" -I"$OUT" "$OUT/${MOD}_lock.cpp" "$OUT/obj/libV${TOP}.a" "$OUT/obj/libverilated.a" -o "$OUT/lock_${MOD}.dylib" 2>"$OUT/dylib.log" \
    || { echo "PLUGIN BUILD FAILED, see $OUT/dylib.log"; head -20 "$OUT/dylib.log"; exit 1; }
fi
[ -z "${BUILD_ONLY:-}" ] || { echo "built $OUT/lock_${MOD}.dylib"; exit 0; }
cd "$REF"
if [ -n "$CYC" ]; then export TTG_REC_N=$CYC; fi
TTG_REC="$OUT/lock_${MOD}.dylib" build/simulator "$PROG" 2>&1 | grep -aE "LOCKSTEP|MISMATCH|inputs this cycle|^    " | head -60
