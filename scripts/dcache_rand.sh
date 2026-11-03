#!/usr/bin/env bash
# Random-stimulus lock-step campaign of the DCache domain (harness/include/ttg_dcache_rand.cpp): the reference MemSubsystem is driven with random
# LSU requests and a random-latency AXI model, the RTL is compared tick by tick.  Needs REFSIM (memsys-tap refsim).
#   usage: dcache_rand.sh [prog.bin]      env: TTG_RAND_CYCLES (per configuration, default 100000), TTG_RAND_SEED, TTG_RAND_CFG, NOBUILD, VFLAGS, TTG_MUT
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export REFSIM=${REFSIM:?set REFSIM}
PROG=${1:-/Users/ruyaoh/personal/tututugege-trace/build/tests/dummy/dummy.bin}
export TICKS_END=$ROOT/harness/include/ttg_dcache_rand.cpp
if [ -z "${NOBUILD:-}" ]; then BUILD_ONLY=1 VFLAGS="${VFLAGS:---assert}" bash "$ROOT/scripts/lockstep_ticks.sh" dcache x 2>&1 | tail -3; fi
cd "$REFSIM" && TTG_REC_END="$ROOT/build/lockt_dcache/lock_dcache.dylib" build/simulator "$PROG" 2>&1 | grep -aE "^LOCKSTEP|MISMATCH|%Error|dcache_rand|inputs this|^    " | head -60
