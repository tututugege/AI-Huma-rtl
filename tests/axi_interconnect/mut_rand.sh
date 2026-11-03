#!/usr/bin/env bash
# survivors of the program-based mutation run, re-run on the random-traffic driver (all features on); needs rand_run.sh BUILD_ONLY first
# usage: tests/axi_interconnect/mut_rand.sh <mut_ic.py workdir>   (REFSIM not needed: the driver links the reference objects)
W=${1:?workdir of mut_ic.py build}
R=$(cd "$(dirname "$0")/../.." && pwd)
DRV=$R/build/rand_axi_interconnect_4096x16/rand_axi
PLUG=$W/build/lock_axi_interconnect.dylib
ls $DRV $PLUG > /dev/null || exit 1
for k in ${MUTS:-6 8 9 10 12 14 16 17 18}; do
  res=SURVIVED
  for cfg in "4096 16" "8 4" "16 2"; do
    set -- $cfg
    for sd in 1 2; do
      out=$(TTG_MUT=$k TTG_LLC_KB=$1 TTG_LLC_WAYS=$2 TTG_REC_END=$PLUG $DRV $sd 30000 2>&1 | grep -aE "MISMATCH" | head -1)
      if [ -n "$out" ]; then res="KILLED (random, ${1}KB/${2}w seed $sd): $out"; break 2; fi
    done
  done
  echo "M$k $res"
done
echo RMUTDONE
