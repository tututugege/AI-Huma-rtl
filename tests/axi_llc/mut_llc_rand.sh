#!/usr/bin/env bash
# LLC mutants (build: 32 sets x 4 ways) on the random-traffic driver (no bypass writes / partial strobes: not implemented in the RTL)
# usage: tests/axi_llc/mut_llc_rand.sh <mut_llc.py workdir built with `build <dir> 32 4`>
W=${1:?workdir of mut_llc.py build}
R=$(cd "$(dirname "$0")/../.." && pwd)
DRV=$R/build/rand_axi_interconnect_4096x16/rand_axi
PLUG=$W/build/lock_axi_llc.dylib
for k in ${MUTS:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16}; do
  res=SURVIVED
  for sd in 1 2 3; do
    out=$(RAND_PWR=0 RAND_PARTIAL=0 TTG_MUT=$k TTG_LLC_KB=8 TTG_LLC_WAYS=4 TTG_REC_END=$PLUG $DRV $sd 30000 2>&1 | grep -aE "MISMATCH|unreachable" | head -1)
    if [ -n "$out" ]; then res="KILLED (random 8KB/4w seed $sd): $out"; break; fi
  done
  echo "M$k $res"
done
echo RLMUTDONE
