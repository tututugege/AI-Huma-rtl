#!/usr/bin/env bash
# Lint RTL: project style rules (svlint) + Verilator -Wall (all warnings fatal).
#   usage: lint.sh [rtl-dir...]     default: every module directory under rtl/ (e.g. rtl/backend/prf) and rtl/common
#   env  LINT_ROOT  lint another checkout (coordinator review)
# Cost is linear in the number of modules: a module directory is compiled once with its own files, the common
# primitives and every package (packages are cheap); other modules' code is NOT pulled in.
set -euo pipefail
TOOLS=$(cd "$(dirname "$0")" && pwd)
ROOT=${LINT_ROOT:-$(cd "$TOOLS/.." && pwd)}
cd "$ROOT"
PKGS=(); while IFS= read -r f; do PKGS+=("$f"); done < <(bash "$TOOLS/rtl_files.sh" . | grep '_pkg\.sv$')
PRIMS=(); while IFS= read -r f; do PRIMS+=("$f"); done < <(find rtl/common -name 'ttg_*.sv' ! -name '*_pkg.sv' | sort)

if [ $# -gt 0 ]; then DIRS=("$@"); else
  DIRS=(); while IFS= read -r d; do DIRS+=("$d"); done < <(find rtl -mindepth 2 -maxdepth 2 -type d | sort)
  DIRS+=(rtl/common)
fi

vlint() {   # vlint <top> <files...>
  local top=$1; shift
  local out; out=$(verilator --lint-only -Wall ${VLINT_EXTRA:-} --top-module "$top" -Irtl/common "${PKGS[@]}" ${NOPRIMS:+} $( [ -n "${NOPRIMS:-}" ] || printf "%s " "${PRIMS[@]}" ) "$@" 2>&1 || true)
  if echo "$out" | grep -qE "^%(Warning|Error)"; then echo "$out" | grep -E "^%(Warning|Error)" -A3 | head -24; echo "LINT FAIL: top=$top"; return 1; fi
}

n=0
for d in "${DIRS[@]}"; do
  files=(); while IFS= read -r f; do files+=("$f"); done < <(find "$d" -name '*.sv' ! -name '*_pkg.sv' | sort)
  allf=(); while IFS= read -r f; do allf+=("$f"); done < <(find "$d" -name '*.sv' | sort)
  [ ${#allf[@]} -gt 0 ] || continue
  # axi_subsys: assembly top with a Verilator UNOPTFLAT on axi_llc.in_w (open item in docs/07-roadmap.md); style-checked only
  if [ "$(basename "$d")" = axi_subsys ]; then python3 "$TOOLS/../harness/tools/svlint.py" "${allf[@]}"; n=$((n + ${#allf[@]})); continue; fi
  python3 "$TOOLS/../harness/tools/svlint.py" "${allf[@]}"
  n=$((n + ${#allf[@]}))
  [ ${#files[@]} -gt 0 ] || continue   # packages only: linted through the modules that use them
  base=$(basename "$d")
  if [ "$base" = back_top ] || [ "$base" = core_top ] || [ "$base" = soc_top ] || [ "$base" = mem_top ]; then
    # assembly of several modules from other directories: compile against all RTL, top = back_top
    ALL=(); while IFS= read -r f; do ALL+=("$f"); done < <(bash "$TOOLS/rtl_files.sh" . | grep -v '_pkg\.sv$' | grep -v -e '^rtl/common/')
    # soc_top/mem_top: the interconnect<->LLC handshake is one struct-granularity UNOPTFLAT (no real loop, simulates fine)
    case "$base" in soc_top|mem_top) export VLINT_EXTRA=-Wno-UNOPTFLAT;; *) unset VLINT_EXTRA;; esac
    vlint "$base" "${ALL[@]}" || exit 1
  elif [ "$base" = front_top ]; then
    FT=(); while IFS= read -r f; do FT+=("$f"); done < <(find rtl/frontend rtl/backend/tlb_mmu -name '*.sv' ! -name '*_pkg.sv' | sort)
    vlint front_top "${FT[@]}" || exit 1
  elif [ "$base" = icache ]; then
    # icache instantiates the ITLB (tlb_mmu_core) from rtl/backend/tlb_mmu: compile against both directories
    IC=(); while IFS= read -r f; do IC+=("$f"); done < <(find rtl/frontend/icache rtl/backend/tlb_mmu -name '*.sv' ! -name '*_pkg.sv' | sort)
    vlint icache "${IC[@]}" || exit 1
  elif [ "$d" = rtl/common ]; then
    for f in "${files[@]}"; do NOPRIMS=1 vlint "$(basename "$f" .sv)" "$f" || exit 1; done
  elif [ -f "$d/$base.sv" ] || find "$d" -name "$base.sv" | grep -q .; then
    # one top named like the directory: its sub-modules are linted through the hierarchy
    vlint "$base" "${files[@]}" || exit 1
  else
    # several independent tops (e.g. a bank of functional units): each file is a top, within this directory only
    for f in "${files[@]}"; do vlint "$(basename "$f" .sv)" "${files[@]}" || exit 1; done
  fi
done
echo "lint ok ($n files, ${#DIRS[@]} dirs)"
