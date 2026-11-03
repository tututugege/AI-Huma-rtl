#!/usr/bin/env bash
cd "$(dirname "$0")/refsim_cov2"
N=${N:-300000}
rm -f build/axi-interconnect-kit/axi_interconnect/*.gcda
for cfg in "TTG_LLC_KB=32 TTG_LLC_WAYS=16" "TTG_LLC_KB=8 TTG_LLC_WAYS=4" "TTG_LLC_KB=16 TTG_LLC_WAYS=2" "TTG_LLC_KB=4096"; do
while read -r p; do
  env $cfg TTG_REC=$PWD/../covplug.dylib TTG_MULTI=1 TTG_REC_N=$N ./build/simulator_cov "$p" > /dev/null 2>&1
done < ../progs68.txt
echo "cfg $cfg done"
done
echo DONE
