#!/usr/bin/env bash
# Cycle-count / front.out equivalence of the tapped simulator against the untouched one.
#   usage: verify.sh <prog.bin> <N cycles>      env: REFSIM (patched, with tap), ORIGSIM (original refsim), PLUGDIR (dir with chk_orig.dylib chk_tap.dylib)
# chk_*.dylib: build_plugin.sh <refsim> chk.cpp out.dylib [-DUSE_TAP for the patched one]
set -euo pipefail
: "${REFSIM:?}" "${ORIGSIM:?}" "${PLUGDIR:?}"
prog=$1; n=$2
a=$(cd "$ORIGSIM" && CHK_N=$n TTG_REC=$PLUGDIR/chk_orig.dylib build/simulator "$prog" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^CHK" | head -1)
b=$(cd "$REFSIM" && CHK_N=$n TTG_REC=$PLUGDIR/chk_tap.dylib build/simulator "$prog" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^CHK" | head -1)
ha=${a% taphash*}; hb=${b% taphash*}
[ "$ha" = "$hb" ] && r=IDENTICAL || r=DIFFERENT
echo "$(basename "$prog") N=$n orig:[$ha] tapped:[$hb] => $r"
