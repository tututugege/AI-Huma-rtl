#!/usr/bin/env bash
# Record traces of one module from the reference simulator (refsim, see refsim_setup.sh).
#   usage: record.sh <module> <program.bin>...        env CYCLES (default 200000): cycles recorded from reset
# Needs spec/<module>.io with an `@ expr` on every field. Writes traces/<module>/<program>.trc.
# Only the first CYCLES cycles are recorded (the RTL starts from reset, so a trace cannot start mid-run).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$1; shift
CYCLES=${CYCLES:-200000}
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}   # shared, read-only; built by refsim_setup.sh
[ -x "$REF/build/simulator" ] || { echo "refsim not built: run scripts/refsim_setup.sh"; exit 2; }
SPEC=$ROOT/spec/$MOD.io; [ -f "$SPEC" ] || SPEC=$MOD   # allow a spec path
OUT=$ROOT/build/$(basename "$SPEC" .io); mkdir -p "$OUT" "$ROOT/traces/$(basename "$SPEC" .io)"
MOD=$(basename "$SPEC" .io)
if [ -z "${NOBUILD:-}" ]; then
  python3 "$ROOT/harness/tools/iogen.py" "$SPEC" "$OUT" >/dev/null
  [ -f "$OUT/${MOD}_rec.cpp" ] || { echo "spec has no @ expressions"; exit 2; }
  INC=""
  for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
           MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end \
           axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
           axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do
    INC="$INC -I$REF/$d"
  done
  clang++ -std=c++2a -O1 -w -fPIC -shared -undefined dynamic_lookup -DNDEBUG $INC \
    -I"$ROOT/harness/include" -I"$OUT" "$OUT/${MOD}_rec.cpp" -o "$OUT/rec_${MOD}.dylib" 2>&1 | head -30
  [ -f "$OUT/rec_${MOD}.dylib" ] || { echo "recorder compile failed"; exit 1; }
fi
for prog in "$@"; do
  name=$(basename "$prog" .bin)
  tr="$ROOT/traces/$MOD/$name.trc"
  ( cd "$REF" && TTG_REC="$OUT/rec_${MOD}.dylib" TTG_REC_OUT="$tr" TTG_REC_N=$CYCLES SIM_MAX_CYCLES=$CYCLES \
      build/simulator "$prog" >"$OUT/sim_$name.log" 2>&1 || true )
  echo "recorded $tr ($(du -h "$tr" | cut -f1), $(( ($(stat -f %z "$tr") ) )) bytes)"
done
