#!/usr/bin/env bash
# Mutation check of the icache RTL: apply ONE textual mutation to a scratch copy, run (a) the whole-program lock-step of spec/icache.io on a few real
# programs, (b) the replay of the random traces.  Prints "<REAL caught-by|-> <RANDOM caught-by|->".
#   usage: mut.sh <rtl-file> <old> <new>      env REFSIM (refsim copy with the icache tap), PROGS (space separated .bin list), CYC (cycles per program)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
F=$1; OLD=$2; NEW=$3
T=$(mktemp -d "${TMPDIR:-/tmp}/icmut.XXXXXX")
cp -R "$ROOT/rtl" "$ROOT/spec" "$ROOT/scripts" "$ROOT/harness" "$T/"
python3 - "$T/$F" "$OLD" "$NEW" <<'PY' || { rm -rf "$T"; echo "PATTERN NOT FOUND: $OLD"; exit 2; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) >= 1, "pattern not found"
open(p, "w").write(s.replace(old, new, 1))
PY
G=/Users/ruyaoh/personal/tututugege-trace/build
PROGS=${PROGS:-"$G/tests/smc-div/smc-div.bin $G/vm/vm-sum-fetch-test/vm_sum_fetch_test.bin $G/tests/fence-i-self-modify/fence-i-self-modify.bin /tmp/big/dhrystone.bin /tmp/big/coremark.bin"}
CYC=${CYC:-300000}
real="-"
if ! BUILD_ONLY=1 bash "$T/scripts/lockstep.sh" icache x >"$T/b.log" 2>&1; then real="BUILDFAIL"; else
  for p in $PROGS; do
    out=$(NOBUILD=1 bash "$T/scripts/lockstep.sh" icache "$p" "$CYC" 2>&1)
    if echo "$out" | grep -aq MISMATCH; then real="$(basename "$p" .bin):$(echo "$out" | grep -a MISMATCH | head -1 | sed 's/^ *MISMATCH //' | cut -c1-60)"; break; fi
  done
fi
rnd="-"
if [ "$real" != "BUILDFAIL" ]; then
  ( cd "$T" && bash scripts/replay.sh icache $ROOT/traces/icache/rand_1.trc >r.log 2>&1 )
  if grep -aq "^FAIL\|MISMATCH" "$T/r.log"; then rnd="$(grep -a MISMATCH "$T/r.log" | head -1 | sed 's/^ *MISMATCH //' | cut -c1-60)"; fi
fi
echo "REAL: $real | RANDOM: $rnd  <= $F: $OLD -> $NEW"
rm -rf "$T"
