#!/usr/bin/env bash
# usage: REFSIM=... tests/axi_interconnect/mut_all.sh <workdir> <12-program list>   (default LLC, then survivors on 3 small LLCs)
cd "$(dirname "$0")/../.."
: "${REFSIM:?set REFSIM}"; W=${1:?workdir}; LST=${2:?program list}
S=$W
echo "=== default 4 MiB LLC, 12 programs x 150000 cycles, all mutants"
python3 tests/axi_interconnect/mut_ic.py run $W $LST 150000 > $S/mut_default.log 2>&1
cat $S/mut_default.log
SURV=$(grep SURVIVED $S/mut_default.log | sed 's/^M *\([0-9]*\) .*/\1/' | tr '\n' ' ')
echo "survivors: $SURV"
for cfg in "32 16" "16 2" "8 4"; do
  set -- $cfg
  echo "=== small LLC ${1}KB x ${2} ways, survivors"
  TTG_LLC_KB=$1 TTG_LLC_WAYS=$2 python3 tests/axi_interconnect/mut_ic.py run $W $LST 150000 $SURV > $S/mut_small_$1_$2.log 2>&1
  cat $S/mut_small_$1_$2.log
  SURV=$(grep SURVIVED $S/mut_small_$1_$2.log | sed 's/^M *\([0-9]*\) .*/\1/' | tr '\n' ' ')
  echo "survivors: $SURV"
done
echo MUTDONE
