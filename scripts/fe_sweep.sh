#!/usr/bin/env bash
# fe_sweep.sh <rtl-root> <R,B>...: front-end switch sweep.  Per setting: copy the tree (without build/), set FE_RFAST / FE_BFAST in the generated
# package, build the function-model testbench, run fm_gate against scripts/fe_refs/ref_r<R>_b<B>.txt (trace-model exp/fe-refs, same bits).
# Results: <rtl-root>_r<R>_b<B>/gate.out and build/gate/summary.txt.  env PAR (settings at a time, default 3), BJOBS (verilator -j, 6), GJOBS (programs, 4).
set -uo pipefail
ROOT=$(cd "$1" && pwd); shift
one() {
  R=${1%,*}; B=${1#*,}; D=${ROOT}_r${R}_b${B}
  rm -rf "$D"; mkdir -p "$D/build/lock_core_top"
  (cd "$ROOT" && tar cf - --exclude=./build .) | tar xf - -C "$D"
  cp "$ROOT/build/lock_core_top/core_top_fields.h" "$D/build/lock_core_top/"
  sed -i.bak "s/FE_RFAST = [0-9]*;/FE_RFAST = $R;/; s/FE_BFAST = [0-9]*;/FE_BFAST = $B;/" "$D/rtl/common/ttg_cfg_pkg.sv"
  cd "$D" && SOC_FM=1 SOC_OUT="$D/build/soc_fm" JOBS=${BJOBS:-6} bash tb/soc/build.sh > build_soc.log 2>&1 \
    && REF_CYCLES="$D/scripts/fe_refs/ref_r${R}_b${B}.txt" JOBS=${GJOBS:-4} bash scripts/fm_gate.sh "$D/build/soc_fm/obj/soc_tb" "$D/build/gate" > gate.out 2>&1
  echo "R=$R B=$B: $(tail -2 "$D/gate.out" | tr '\n' ' ')"
}
n=0
for s in "$@"; do
  one "$s" &
  n=$((n + 1)); [ $((n % ${PAR:-3})) = 0 ] && wait
done
wait
