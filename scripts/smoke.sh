#!/usr/bin/env bash
# Daily gate: lock-step of the given modules over the SMOKE set (every program that finishes within ~70k cycles: 61 short gate/vm
# programs + dhrystone(64 runs), each capped at 60k cycles; a few minutes at most).  Full 68-program runs stay in lockstep_multi.sh.
#   usage: smoke.sh <module>...      (16-tick memory-domain modules: use lockstep_ticks_all.sh with PROGS=scripts/progs_smoke.txt)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROGS=$ROOT/scripts/progs_smoke.txt BIG_CYCLES=${BIG_CYCLES:-60000} JOBS=${JOBS:-4} exec bash "$ROOT/scripts/lockstep_multi.sh" "$@"
