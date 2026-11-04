#!/usr/bin/env bash
# Coverage proof for the rare paths of axi_llc: builds a scratch copy of the RTL with tests/axi_llc/cover_events.inc inserted
# into axi_llc_core and counts the events over random-traffic runs.
#   usage: cover_run.sh "<seeds>" [cpu_cycles]   env REFSIM (tap refsim), RAND_PWR/RAND_PARTIAL (default 1), GEOS (default the three small ones)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SEEDS=${1:-"1 2 3 4"}; CYC=${2:-30000}
S=${SCRATCH:-$ROOT/../llc2_scratch/cover}
rm -rf "$S"; mkdir -p "$S/rtl/memsys" "$S/tests"
cp -R "$ROOT/rtl/common" "$S/rtl/common"; cp -R "$ROOT/rtl/memsys/axi_llc" "$S/rtl/memsys/axi_llc"
for d in spec harness scripts refhook; do [ -e "$ROOT/$d" ] && ln -s "$ROOT/$d" "$S/$d"; done
rm "$S/scripts"; cp -R "$ROOT/scripts" "$S/scripts"; cp -R "$ROOT/tests/axi_llc" "$S/tests/axi_llc"
python3 - "$S/rtl/memsys/axi_llc/axi_llc_core.sv" "$ROOT/tests/axi_llc/cover_events.inc" <<'PY'
import sys
p, inc = sys.argv[1:3]
s = open(p).read(); i = s.rindex('endmodule')
open(p, 'w').write(s[:i] + open(inc).read() + s[i:])
PY
export RAND_PWR=${RAND_PWR:-1} RAND_PARTIAL=${RAND_PARTIAL:-1}
GEOS=${GEOS:-"32 16 32 16;8 4 32 4;16 2 128 2"}
IFS=';' read -ra G <<< "$GEOS"
for cfg in "${G[@]}"; do
  read -r KB W SETS WAYS <<< "$cfg"
  export TTG_LLC_KB=$KB TTG_LLC_WAYS=$W SETS=$SETS WAYS=$WAYS
  BUILD_ONLY=1 bash "$S/tests/axi_llc/rand_run.sh" axi_llc 1 $CYC > /dev/null 2>&1 || { echo "build failed $cfg"; exit 1; }
  OUT=$S/build/rand_axi_llc_${SETS}x${WAYS}
  for sd in $SEEDS; do
    TTG_REC_END=$OUT/lock_axi_llc.dylib "$OUT/rand_axi" $sd $CYC 2>&1 | grep -a "^COV\|LOCKSTEP\|MISMATCH" | sort | uniq -c | sed "s/^/${KB}KB\/${W}w seed $sd: /"
  done
done
