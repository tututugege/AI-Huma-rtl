#!/usr/bin/env bash
# usage: REFSIM=<tap refsim tree> tests/axi_llc/rand_all.sh   (random-traffic lock-step matrix: subsys on 3 small LLCs, interconnect on 4 geometries)
cd "$(dirname "$0")/../.."
: "${REFSIM:?set REFSIM}"
run() {  # module kb ways sets ways_rtl seeds cycles [env...]
  local mod=$1 kb=$2 w=$3 sets=$4 seeds=$5 cyc=$6; shift 6
  export TTG_LLC_KB=$kb TTG_LLC_WAYS=$w SETS=$sets WAYS=$w
  echo "### $mod KB=$kb ways=$w sets=$sets cycles=$cyc env: $*"
  env "$@" JOBS=3 BUILD_ONLY=1 bash tests/axi_llc/rand_run.sh $mod 1 1 > /dev/null 2>&1 || { echo BUILD FAILED; return; }
  for sd in $seeds; do
    echo "seed $sd: $(env "$@" NOBUILD=1 bash tests/axi_llc/rand_run.sh $mod $sd $cyc 2>&1 | grep -aE 'LOCKSTEP|MISMATCH|rand_axi: max|unreachable|Error|full' | tr '\n' ' ' | cut -c1-300)"
  done
}
for g in "8 4 32" "16 2 128" "32 16 32"; do
  set -- $g
  run axi_subsys $1 $2 $3 "1 2 3 4" 30000 RAND_PWR=0 RAND_PARTIAL=0
done
for g in "4096 16 4096" "8 4 32" "16 2 128"; do
  set -- $g
  run axi_interconnect $1 $2 $3 "1 2 3 4" 30000 RAND_PWR=1 RAND_PARTIAL=1
done
echo RANDDONE
