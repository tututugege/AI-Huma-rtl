#!/usr/bin/env bash
# Fast-tick variant of lockstep.sh for the memory-subsystem domains (16 RTL clocks per CPU cycle).
#   usage: lockstep_ticks.sh <module> <program.bin> [cycles]   env REFSIM = refsim tree patched with docs/analysis/memsys-record-hook.patch
# The generated lock plugin's ttg_rec_cycle (one comparison + one RTL clock) is called for tick 0..15 of every CPU cycle by
# harness/include/ttg_ticks_end.cpp (symbol ttg_rec_cycle_end, driven through $TTG_REC_END).  [cycles] counts CPU cycles.
# Same options as lockstep.sh: BUILD_ONLY, NOBUILD, VFLAGS, EXTRA_CPP, COVERAGE; TICKS_END=<cpp> replaces the end-of-cycle hook (random campaign: dcache_rand.sh).   Prints LOCKSTEP PASS <mod>: N cycles compared (N counts TICKS).
# The Verilated RTL is compiled into a plugin loaded by the instrumented reference simulator; every cycle the reference's
# module-boundary values drive the RTL and every RTL output is compared at once. Prints "LOCKSTEP PASS <mod>: N cycles
# compared" or the first mismatch (cycle, field, values, inputs) and exits 1.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1; PROG=${2:-}; CYC=${3:-}
REF=${REFSIM:?set REFSIM to the memsys-tap refsim tree}
SPEC=$ROOT/spec/$MOD.io; [ -f "$SPEC" ] || { echo "missing $SPEC"; exit 2; }
OUT=$ROOT/build/lockt_$MOD; mkdir -p "$OUT"
if [ -z "${NOBUILD:-}" ]; then
  python3 "$ROOT/harness/tools/iogen.py" "$SPEC" "$OUT" >/dev/null
  FILES=(); while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT")
  TOP=${MOD}_tbwrap
  ( cd "$OUT" && verilator --cc --build -j 4 -Wall ${VFLAGS:-} --x-assign 0 --x-initial 0 --top-module "$TOP" -Mdir obj \
      ${COVERAGE:+${COV_FLAGS:---coverage-line} --output-split 4000 --output-split-cfuncs 800} -CFLAGS "${COVERAGE:+-O0 }-O2 -fPIC" "$OUT/${TOP}.sv" "${FILES[@]}" >build.log 2>&1 ) || { echo "RTL BUILD FAILED ($MOD), see $OUT/build.log"; grep -E "%(Error|Warning)" "$OUT/build.log" | head -10; exit 1; }
  VINC=$(verilator --getenv VERILATOR_ROOT)/include
  INC=""
  for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
           MemSubSystem/include diff/include function-model/include/api legacy/mmu/include front-end \
           axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
           axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC="$INC -I$REF/$d"; done
  clang++ -std=c++2a -O2 -w -fPIC -shared -undefined dynamic_lookup -DNDEBUG ${COVERAGE:+-DTTG_COVERAGE} $INC -I"$VINC" -I"$VINC/vltstd" -I"$OUT/obj" \
    -include memsys_tap.h -I"$ROOT/harness/include" -I"$OUT" "$OUT/${MOD}_lock.cpp" "${TICKS_END:-$ROOT/harness/include/ttg_ticks_end.cpp}" ${EXTRA_CPP:-} "$OUT/obj/libV${TOP}.a" "$OUT/obj/libverilated.a" -o "$OUT/lock_${MOD}.dylib" 2>"$OUT/dylib.log" \
    || { echo "PLUGIN BUILD FAILED, see $OUT/dylib.log"; head -20 "$OUT/dylib.log"; exit 1; }
fi
[ -z "${BUILD_ONLY:-}" ] || { echo "built $OUT/lock_${MOD}.dylib"; exit 0; }
cd "$REF"
export TTG_COV_FILE="$OUT/coverage.dat"
if [ -n "$CYC" ]; then export TTG_REC_N=$((CYC * 16)); fi
TTG_REC_END="$OUT/lock_${MOD}.dylib" build/simulator "$PROG" 2>&1 | grep -aE "LOCKSTEP|MISMATCH|inputs this cycle|^    " | head -60
