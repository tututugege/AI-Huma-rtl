#!/usr/bin/env bash
# Equivalence test of the merged rtl/backend/ren/ren_free_list.sv (INT defaults and the FP parameters of ren_fp.sv)
# against copies of the two modules it replaced (tests/ren_free_list/ren_free_list_ref_{int,fp}.sv).
#   usage: run.sh [cycles=1000000]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$ROOT/build/test_ren_free_list}
mkdir -p "$OUT"
PKGS=(); while IFS= read -r f; do PKGS+=("$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT" | grep '_pkg\.sv$' | sed "s|^\./|$ROOT/|; s|^rtl/|$ROOT/rtl/|")
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
verilator --binary -j "$JOBS" -Wno-fatal -Wno-lint -Wno-style --top-module eq_top -GNVEC="${1:-1000000}" -Mdir "$OUT/obj" \
  "${PKGS[@]}" "$ROOT/rtl/common/ttg_onehot_mux.sv" "$ROOT/rtl/backend/ren/ren_free_list.sv" \
  "$ROOT/tests/ren_free_list/ren_free_list_ref_int.sv" "$ROOT/tests/ren_free_list/ren_free_list_ref_fp.sv" \
  "$ROOT/tests/ren_free_list/eq_top.sv" \
  > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
"$OUT/obj/Veq_top"
