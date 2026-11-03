#!/usr/bin/env bash
# Harness selftest:  (1) the correct toy RTL must PASS a golden trace,
#                    (2) every seeded RTL bug (mutant) must FAIL it, naming the right field.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
B=$ROOT/build/selftest; mkdir -p "$B" "$ROOT/traces"
cd "$ROOT"

bash scripts/hbuild.sh tests/selftest/toy_fifo.io "$B" tests/selftest/toy_fifo.sv || exit 1
clang++ -std=c++17 -O1 -Iharness/include -I"$B" tests/selftest/toy_golden.cpp -o "$B/toy_golden" || exit 1
"$B/toy_golden" traces/toy.trc 20000 7 || exit 1

fail=0
echo "== clean RTL"
"$B/replay" traces/toy.trc | tail -1 | grep -q '^PASS' && echo "  ok: PASS" || { echo "  FAIL: clean RTL did not pass"; fail=1; }

# name | sed-style python substitution (old -> new) | field that must be reported
MUTANTS=(
  "full_early|count_q < 3'd4|count_q < 3'd3|push_ready"
  "pop_stale|mem_q[head_q];|mem_q[tail_q];|pop_data"
  "count_dec|count_q + 3'(do_push) - 3'(do_pop)|count_q + 3'(do_push)|count"
  "wrap_head|head_d = head_q + 2'd1;|head_d = head_q + 2'd2;|slot_valid"
  "blob_rot|{blob[78:0], blob[79]}|{blob[78:0], ~blob[79]}|blob_rot"
  "lane_idx|4'(r * 2 + c)|4'(r * 2 + r)|lane_sum"
  "flush_keeps_tail|tail_d  = 2'd0;|tail_d  = tail_q;|pop_data"
  "data_hi_bit|mem_d[tail_q] = push_data;|mem_d[tail_q] = push_data ^ 8'h80;|slot_data"
)
for m in "${MUTANTS[@]}"; do
  IFS='|' read -r name old new field <<<"$m"
  d="$B/mut_$name"; mkdir -p "$d"
  python3 - "$old" "$new" "$d/toy_fifo.sv" <<'EOF'
import sys
old, new, out = sys.argv[1:]
s = open("tests/selftest/toy_fifo.sv").read()
assert old in s, f"mutation pattern not found: {old}"
open(out, "w").write(s.replace(old, new, 1))
EOF
  [ $? -eq 0 ] || { echo "  FAIL: $name: pattern missing"; fail=1; continue; }
  bash scripts/hbuild.sh tests/selftest/toy_fifo.io "$d" "$d/toy_fifo.sv" >/dev/null || { echo "  FAIL: $name: build"; fail=1; continue; }
  out=$("$d/replay" traces/toy.trc --vcd "$d/fail.vcd" --max-fail 4)
  if echo "$out" | grep -q '^FAIL' && echo "$out" | grep -q "MISMATCH.* $field"; then
    echo "  ok: mutant $name caught ($(echo "$out" | grep '^FAIL' | sed 's/.*first mismatch at //'))"
  else
    echo "  FAIL: mutant $name NOT caught as $field"; echo "$out" | head -5; fail=1
  fi
  [ -s "$d/fail.vcd" ] || { echo "  FAIL: $name: no vcd written"; fail=1; }
done

echo "== spec-change guard"
# a compare-rule change (no `when`) must NOT change the hash; a layout change (field order) must
sed 's/^out pop_data   8  when pop_valid/out pop_data   8/' tests/selftest/toy_fifo.io > "$B/toy_fifo_rule.io"
h1=$(python3 harness/tools/iogen.py tests/selftest/toy_fifo.io "$B/h1" | sed 's/.*hash=//'); h2=$(python3 harness/tools/iogen.py "$B/toy_fifo_rule.io" "$B/h2" | sed 's/.*hash=//')
[ "$h1" = "$h2" ] && echo "  ok: compare-rule change keeps the hash" || { echo "  FAIL: when changes the hash"; fail=1; }
python3 - "$B/toy_fifo_changed.io" <<'PY'
import sys
L = open('tests/selftest/toy_fifo.io').read().split('\n')
i, j = [k for k, l in enumerate(L) if l.startswith('in  pop_ready') or l.startswith('in  flush')]
L[i], L[j] = L[j], L[i]
open(sys.argv[1], 'w').write('\n'.join(L))
PY
mkdir -p "$B/spec2"
if bash scripts/hbuild.sh "$B/toy_fifo_changed.io" "$B/spec2" tests/selftest/toy_fifo.sv >/dev/null 2>&1; then
  out=$("$B/spec2/replay" traces/toy.trc 2>&1 || true)
  echo "$out" | grep -q 're-record the trace' && echo "  ok: stale trace rejected" || { echo "  FAIL: stale trace accepted"; fail=1; }
else
  echo "  FAIL: changed spec did not build"; fail=1
fi

echo "== svlint rules"
lint_out=$(python3 harness/tools/svlint.py tests/selftest/lint_bad.sv || true)
for r in S1 S2 S4 S5 S6 S7 S8 S9 S11 S12; do
  echo "$lint_out" | grep -q " $r " && echo "  ok: $r flagged" || { echo "  FAIL: svlint did not flag $r"; fail=1; }
done
python3 harness/tools/svlint.py tests/selftest/toy_fifo.sv tests/selftest/lint_cmp_ok.sv && echo "  ok: clean files (incl. <= comparison) pass svlint" || { echo "  FAIL: toy_fifo flagged"; fail=1; }

[ $fail -eq 0 ] && echo "SELFTEST PASS" || { echo "SELFTEST FAIL"; exit 1; }
