#!/usr/bin/env bash
# Mutation check of the BPU RTL against the live whole-program lock-step.
#   usage: mut.sh <spec> <rtl-file> <old> <new> <program.bin> <cycles>
# Copies rtl/spec/scripts/harness to a scratch tree, applies ONE textual mutation, builds the lock-step plugin for <spec> and
# runs it; prints "CAUGHT <spec>: <first mismatch line>" or "SURVIVED".   env REFSIM (refsim_tap, read only)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SPEC=$1; F=$2; OLD=$3; NEW=$4; PROG=$5; CYC=$6
T=$(mktemp -d "${TMPDIR:-/tmp}/bpumut.XXXXXX")
cp -R "$ROOT/rtl" "$ROOT/spec" "$ROOT/scripts" "$ROOT/harness" "$T/"
python3 - "$T/$F" "$OLD" "$NEW" <<'PY' || { rm -rf "$T"; echo "PATTERN NOT FOUND: $OLD"; exit 2; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) >= 1, "pattern not found"
open(p, "w").write(s.replace(old, new, 1))
PY
export REFSIM=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim_tap}
out=$(bash "$T/scripts/lockstep.sh" "$SPEC" "$PROG" "$CYC" 2>&1)
if echo "$out" | grep -q "LOCKSTEP PASS"; then echo "SURVIVED  $F: $OLD -> $NEW"; else
  echo "CAUGHT    $F: $OLD -> $NEW :: $(echo "$out" | grep -a MISMATCH | head -1)"; fi
rm -rf "$T"
