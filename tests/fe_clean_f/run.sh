#!/usr/bin/env bash
# Cleanup F (2026-11-29) equivalence tests: new rtl/frontend against the pre-cleanup copies in ref/ (rtl HEAD 3834bbe).
#   usage: run.sh [test...]     tests: chain (items 1-3, NCYC cycles), decode (item 3 + rvc_expand, exhaustive 16-bit +
#                               random 32-bit), ctrl (front_ctrl fold), spec (bpu_spec 1-slot RAS overlay)
#   env    NCYC=1000000  cycles / vectors of the random tests
#          MUT=<n>       mutant check: build with mutant n of the new RTL (see mutants below); the test must FAIL
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/tests/fe_clean_f"
OUT=${OUT:-$ROOT/build/test_fe_clean_f}
NCYC=${NCYC:-1000000}
mkdir -p "$OUT"
PKGS=(); while IFS= read -r f; do PKGS+=("$ROOT/${f#./}"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT" | grep '_pkg\.sv$')
PRIMS=("$ROOT"/rtl/common/ttg_first_set.sv "$ROOT"/rtl/common/ttg_onehot_mux.sv "$ROOT"/rtl/common/ttg_onehot_to_idx.sv)
FE="$ROOT/rtl/frontend"
REF=("$HERE"/ref/*_ref.sv)
NEW=("$FE/icache/icache_resp.sv" "$FE/front_top/front_fetch_buf.sv" "$FE/inst_fifo.sv" "$FE/front_head_fix.sv"
     "$FE/predecode_lane.sv" "$FE/rvc_expand.sv" "$FE/predecode_checker.sv" "$FE/front_pd_info.sv" "$FE/front_ctrl.sv"
     "$FE/bpu/bpu_spec.sv" "$FE/bpu/bpu_hist_vec.sv")

# mutants: <file> <perl substitution>; each must make its test FAIL
mutant() {
  case "$1" in
    1) echo "front_top/front_fetch_buf.sv|s/\\(want_straddle && b_ok\\) \\? b_up16 : a_last_up16/a_last_up16/" ;;
    2) echo "front_head_fix.sv|s/s1_v\\[i \\+ 1\\] \\? \\{s1_lo/s1_v[i] ? {s1_lo/" ;;
    3) echo "icache/icache_resp.sv|s/HI_W'\\(FETCH_WIDTH\\)/HI_W'(FETCH_WIDTH - 1)/" ;;
    4) echo "predecode_lane.sv|s/\\(inst\\[31:20\\] == 12'd0\\)/(inst[31:21] == 11'd0)/" ;;
    5) echo "front_pd_info.sv|s/kind\\[i\\] == BR_CALL/kind[i] == BR_JAL/" ;;
    6) echo "front_head_fix.sv|s/kind_o\\[i\\]    = s1_pf\\[i\\] \\? BR_NONCTL : k;/kind_o[i] = k;/" ;;
    7) echo "front_top/front_fetch_buf.sv|s/m_v\\[i\\] \\? b_half\\[j\\] : INST_NOP_LO/b_half[j]/" ;;
    8) echo "rvc_expand.sv|s/3'd0: inst = enc_i\\(OPIMM, rd_f, 3'd1/3'd0: if (!h12) inst = enc_i(OPIMM, rd_f, 3'd1/" ;;
    9) echo "front_ctrl.sv|s/predecode_refetch_address_q <= checker_flush_address;/predecode_refetch_address_q <= do_predecode_flush ? checker_flush_address : predecode_refetch_address_q;/" ;;
    10) echo "bpu/bpu_spec.sv|s/if \\(o.w && o.idx == i\\) v = o.nos;/if (o.w \\&\\& o.idx == i \\&\\& !o.arch) v = o.nos;/" ;;
    *) echo "no mutant $1" >&2; exit 2 ;;
  esac
}
if [ -n "${MUT:-}" ]; then
  IFS='|' read -r mf ms < <(mutant "$MUT")
  MD="$OUT/mut$MUT"; mkdir -p "$MD"
  perl -pe "$ms" "$FE/$mf" > "$MD/$(basename "$mf")"
  if cmp -s "$FE/$mf" "$MD/$(basename "$mf")"; then echo "mutant $MUT did not apply"; exit 2; fi
  for k in "${!NEW[@]}"; do [ "${NEW[$k]}" = "$FE/$mf" ] && NEW[$k]="$MD/$(basename "$mf")"; done
  OUT="$MD"
fi

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4); [ "$JOBS" -gt 4 ] && JOBS=4
run() {   # run <top>
  local top=$1
  verilator --binary --timing -j "$JOBS" -Wno-fatal -Wno-lint -Wno-style --top-module "$top" -GNCYC="$NCYC" \
    -Mdir "$OUT/obj_$top" "${PKGS[@]}" "$HERE/ref/fe_ref_pkg.sv" "${PRIMS[@]}" "${NEW[@]}" "${REF[@]}" "$HERE/$top.sv" \
    > "$OUT/build_$top.log" 2>&1 || { tail -30 "$OUT/build_$top.log"; exit 1; }
  "$OUT/obj_$top/V$top"
}
TESTS=("$@"); [ ${#TESTS[@]} -gt 0 ] || TESTS=(chain decode ctrl spec)
for t in "${TESTS[@]}"; do run "eq_$t"; done
