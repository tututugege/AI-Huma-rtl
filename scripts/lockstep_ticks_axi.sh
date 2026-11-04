#!/usr/bin/env bash
# Fast-tick lock-step for the AXI interconnect / LLC (16 RTL clocks per CPU cycle), own copy of the dcache script so that no shared file changes.
#   usage: lockstep_ticks_axi.sh <module> <program.bin> [cycles]   (module = axi_ic | axi_llc | axi_sub)
#   env  REFSIM = refsim tree patched with docs/analysis/memsys-record-hook.patch AND axi-record-hook.patch (default $ROOT/../axi_refsim is NOT assumed: set it)
#        TTG_LLC_KB / TTG_LLC_WAYS = shrink the LLC in the reference (the RTL must be built for the same geometry: LLC_SETS/LLC_WAYS via VFLAGS)
#        BUILD_ONLY, NOBUILD, VFLAGS, EXTRA_CPP, COVERAGE  as in lockstep.sh      [cycles] = CPU cycles (N counts TICKS in the PASS line)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1; PROG=${2:-}; CYC=${3:-}
REF=${REFSIM:?set REFSIM to the memsys+axi tap refsim tree}
SPEC=$ROOT/spec/$MOD.io; [ -f "$SPEC" ] || { echo "missing $SPEC"; exit 2; }
OUT=${OUTDIR:-$ROOT/build/lockta_$MOD}; mkdir -p "$OUT"
if [ -z "${NOBUILD:-}" ]; then
  python3 "$ROOT/harness/tools/iogen.py" "$SPEC" "$OUT" >/dev/null
  FILES=(); while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT")
  TOP=${MOD}_tbwrap
  ( cd "$OUT" && verilator --cc --build -j ${JOBS:-4} -Wall ${VFLAGS:-} --x-assign 0 --x-initial 0 --top-module "$TOP" -Mdir obj \
      ${COVERAGE:+${COV_FLAGS:---coverage-line} --output-split 4000 --output-split-cfuncs 800} -CFLAGS "${COVERAGE:+-O0 }-O2 -fPIC" "$OUT/${TOP}.sv" "${FILES[@]}" >build.log 2>&1 ) || { echo "RTL BUILD FAILED ($MOD), see $OUT/build.log"; grep -E "%(Error|Warning)" "$OUT/build.log" | head -10; exit 1; }
  VINC=$(verilator --getenv VERILATOR_ROOT)/include
  INC=()
  for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
           MemSubSystem/include diff/include function-model/include/api legacy/mmu/include front-end \
           axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
           axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
  clang++ -std=c++2a -O2 -w -fPIC -shared -undefined dynamic_lookup -DNDEBUG ${COVERAGE:+-DTTG_COVERAGE} "${INC[@]}" -I"$VINC" -I"$VINC/vltstd" -I"$OUT/obj" \
    -include memsys_tap.h -include axi_tap.h -I"$ROOT/harness/include" -I"$OUT" "$OUT/${MOD}_lock.cpp" "$ROOT/harness/include/ttg_ticks_end_axi.cpp" ${EXTRA_CPP:-} \
    "$OUT/obj/libV${TOP}.a" "$OUT/obj/libverilated.a" -o "$OUT/lock_${MOD}.dylib" 2>"$OUT/dylib.log" \
    || { echo "PLUGIN BUILD FAILED, see $OUT/dylib.log"; head -20 "$OUT/dylib.log"; exit 1; }
fi
[ -z "${BUILD_ONLY:-}" ] || { echo "built $OUT/lock_${MOD}.dylib"; exit 0; }
cd "$REF"
export TTG_COV_FILE="$OUT/coverage.dat"
if [ -n "$CYC" ]; then export TTG_REC_N=$((CYC * 16)); fi
TTG_REC_END="$OUT/lock_${MOD}.dylib" build/simulator "$PROG" 2>&1 | grep -aE "LOCKSTEP|MISMATCH|inputs this cycle|^    " | head -${HEADN:-60}
