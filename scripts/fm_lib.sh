#!/usr/bin/env bash
# fm_lib.sh: print the directory of the function-model build the testbenches link (librefcpu.a, include/api, lib/softfloat), building it
# first if needed: revision FM_REV of the function-model repository FM_GIT, XLEN=64 FP=1 RVC=1 (= the RTL), into build/fm-<rev>-x64c1.
# The revision is pinned (env.sh FM_REV, the same as trace-model's Makefile) so no shared, possibly stale or differently configured
# librefcpu.a is linked by accident; the checkout's branch does not matter (git archive). Bump FM_REV in both repositories together.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
D=$ROOT/build/fm-$FM_REV-x64c1
if [ ! -f "$D/librefcpu.a" ]; then
  mkdir -p "$D"
  git -C "$FM_GIT" archive "$FM_REV" | tar -x -C "$D"
  make -s -C "$D" librefcpu.a XLEN=64 FP=1 RVC=1 LDFLAGS=-lz > "$D/build.log" 2>&1 || { tail -20 "$D/build.log" >&2; exit 1; }
fi
echo "$D"
