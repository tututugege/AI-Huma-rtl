#!/usr/bin/env bash
# Lint RTL: project style rules (svlint) + Verilator -Wall (all warnings fatal).
#   usage: lint.sh [rtl-dir...]     default: every module directory under rtl/ (e.g. rtl/backend/prf) and rtl/common,
#                                   plus scripts/lint_chip.sh (top soc_top) and scripts/lint_soc.sh (top chip_top)
#   env  LINT_ROOT  lint another checkout (coordinator review);  LINT_JOBS  parallel directories (default 4)
# Directories run in parallel (one job per directory, output printed in directory order). A module directory is compiled
# once with its own files, the common primitives and only the packages those files need (scripts/list_sv_files.py --pkgs).
# Assembly directories (back_top, core_top, soc_top, mem_top, chip_top, axi_subsys) only get svlint here: their Verilator
# check is the whole-design lint, which lint_chip.sh / lint_soc.sh do (with no arguments this script runs both).
# Unused package constants (UNUSEDPARAM in *_pkg.sv) are judged only by the whole-design lint of chip_top (lint_soc.sh),
# where unused means dead; directory lints waive them through scripts/lint_pkg.vlt.
# Both stages run in every directory; the exit status is non-zero if any stage failed anywhere, and the failing stages
# are listed at the end. svlint S10 (size) lines are notes and never fail.
set -uo pipefail
TOOLS=$(cd "$(dirname "$0")" && pwd)
ROOT=${LINT_ROOT:-$(cd "$TOOLS/.." && pwd)}
cd "$ROOT" || exit 1
PRIMS=(); while IFS= read -r f; do PRIMS+=("$f"); done < <(find rtl/common -name 'ttg_*.sv' ! -name '*_pkg.sv' | sort)

# ---- worker: lint one directory (internal: lint.sh --one <dir>) ----
if [ "${1:-}" = --one ]; then ONE=$2; set --; fi

if [ -n "${ONE:-}" ]; then DIRS=("$ONE"); elif [ $# -gt 0 ]; then DIRS=("$@"); else
  DIRS=(); while IFS= read -r d; do DIRS+=("$d"); done < <(find rtl -mindepth 2 -maxdepth 2 -type d | sort)
  DIRS+=(rtl/common)
fi

vlint() {   # vlint <top> <files...>   (NOPRIMS=1: without the rtl/common primitives)
  local top=$1; shift
  local src=("$@"); [ -n "${NOPRIMS:-}" ] || src+=("${PRIMS[@]}")
  local pk=(); while IFS= read -r f; do pk+=("$f"); done < <(python3 "$TOOLS/list_sv_files.py" --pkgs . "${src[@]}")
  local vlt=("$TOOLS/lint_pkg.vlt"); [ "$top" != chip_top ] || vlt=()
  local out
  out=$(verilator --lint-only -Wall ${VLINT_EXTRA:-} --top-module "$top" -Irtl/common ${vlt[@]+"${vlt[@]}"} ${pk[@]+"${pk[@]}"} "${src[@]}" 2>&1 || true)
  if echo "$out" | grep -qE "^%(Warning|Error)"; then
    echo "$out" | grep -E "^%(Warning|Error)" -A3 | head -${LINT_LINES:-40}; echo "LINT FAIL: top=$top"; return 1
  fi
}

if [ -z "${ONE:-}" ]; then
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/lint.XXXXXX")
  JOBS=${LINT_JOBS:-4}
  # whole-design lints (only for a full run) start first: they are the longest jobs
  WHOLE=(); [ $# -gt 0 ] || WHOLE=(lint_chip lint_soc)
  { for w in ${WHOLE[@]+"${WHOLE[@]}"}; do echo "@$w"; done; printf '%s\n' "${DIRS[@]}"; } | awk '{print NR" "$0}' |
    xargs -P "$JOBS" -L 1 bash -c 'i=$0; d=$1; out="'"$TMP"'/$(printf %04d $i)";
      if [ "${d#@}" != "$d" ]; then bash "'"$TOOLS"'/${d#@}.sh" > "$out.log" 2>&1; echo $? > "$out.rc"; echo "${d#@}.sh" > "$out.name"
      else bash "'"$TOOLS"'/lint.sh" --one "$d" > "$out.log" 2>&1; echo $? > "$out.rc"; echo "$d" > "$out.name"; fi'
  FAILS=(); nf=0
  for f in "$TMP"/*.log; do
    b=${f%.log}; cat "$f"; rc=$(cat "$b.rc"); name=$(cat "$b.name")
    if [ "$rc" != 0 ]; then
      got=0; while IFS= read -r s; do FAILS+=("$s"); got=1; done < <(grep -h '^  ' "$f" | sed 's/^  //')
      [ $got = 1 ] || FAILS+=("$name")
    fi
    m=$(grep -ho 'lint ok ([0-9]* files' "$f" | grep -o '[0-9]*' | head -1); nf=$((nf + ${m:-0}))
  done
  if [ ${#FAILS[@]} -gt 0 ]; then echo "lint FAILED: ${#FAILS[@]} stage(s) (${#DIRS[@]} dirs)"; printf '  %s\n' "${FAILS[@]}"; exit 1; fi
  echo "lint ok (${#DIRS[@]} dirs${WHOLE[@]+, + lint_chip, lint_soc})"; exit 0
fi

n=0; FAILS=()
for d in "${DIRS[@]}"; do
  files=(); while IFS= read -r f; do files+=("$f"); done < <(find "$d" -name '*.sv' ! -name '*_pkg.sv' | sort)
  allf=(); while IFS= read -r f; do allf+=("$f"); done < <(find "$d" -name '*.sv' | sort)
  [ ${#allf[@]} -gt 0 ] || continue
  python3 "$TOOLS/../harness/tools/svlint.py" "${allf[@]}" || FAILS+=("$d: svlint")
  n=$((n + ${#allf[@]}))
  [ ${#files[@]} -gt 0 ] || continue   # packages only: linted through the modules that use them
  base=$(basename "$d"); vok=1
  if [ "$base" = back_top ] || [ "$base" = core_top ] || [ "$base" = soc_top ] || [ "$base" = mem_top ] || [ "$base" = chip_top ] ||
     [ "$base" = axi_subsys ]; then
    :   # assembly of modules from other directories: Verilator check = whole-design lint (lint_chip.sh / lint_soc.sh)
  elif [ "$base" = front_top ]; then
    FT=(); while IFS= read -r f; do FT+=("$f"); done < <(find rtl/frontend rtl/backend/tlb_mmu -name '*.sv' ! -name '*_pkg.sv' | sort)
    vlint front_top "${FT[@]}" || vok=0
  elif [ "$base" = icache ]; then
    # icache instantiates the ITLB (tlb_mmu_core) from rtl/backend/tlb_mmu: compile against both directories
    IC=(); while IFS= read -r f; do IC+=("$f"); done < <(find rtl/frontend/icache rtl/backend/tlb_mmu -name '*.sv' ! -name '*_pkg.sv' | sort)
    vlint icache "${IC[@]}" || vok=0
  elif [ "$base" = soc_xbar ] || [ "$base" = soc_sram ]; then
    # soc_xbar / soc_sram instantiate reusable AXI4 building blocks from rtl/soc/soc_axi
    AX=(); while IFS= read -r f; do AX+=("$f"); done < <(find "$d" rtl/soc/soc_axi -name '*.sv' ! -name '*_pkg.sv' | sort)
    vlint "$base" "${AX[@]}" || vok=0
  elif [ "$d" = rtl/common ]; then
    for f in "${files[@]}"; do NOPRIMS=1 vlint "$(basename "$f" .sv)" "$f" || vok=0; done
  elif [ "${d#rtl/common/}" != "$d" ]; then
    # a primitive family under rtl/common (e.g. sram): its files are already in PRIMS; each file is a top
    for f in "${files[@]}"; do NOPRIMS=1 vlint "$(basename "$f" .sv)" "${files[@]}" || vok=0; done
  elif [ -f "$d/$base.sv" ] || find "$d" -name "$base.sv" | grep -q .; then
    # one top named like the directory: its sub-modules are linted through the hierarchy
    vlint "$base" "${files[@]}" || vok=0
  else
    # several independent tops (e.g. a bank of functional units): each file is a top, within this directory only
    for f in "${files[@]}"; do vlint "$(basename "$f" .sv)" "${files[@]}" || vok=0; done
  fi
  [ $vok = 1 ] || FAILS+=("$d: verilator")
done
if [ ${#FAILS[@]} -gt 0 ]; then
  echo "lint FAILED: ${#FAILS[@]} stage(s) ($n files, ${#DIRS[@]} dirs)"; printf '  %s\n' "${FAILS[@]}"; exit 1
fi
echo "lint ok ($n files, ${#DIRS[@]} dirs)"
