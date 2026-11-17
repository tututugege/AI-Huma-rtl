#!/usr/bin/env bash
# run.sh [cycles]: equivalence of the parallel tlb_mmu_core against the old serial one (committed rv64 config package)
set -euo pipefail
cd "$(dirname "$0")/../.."
N=${1:-1000000}
B=build/tlb_par
mkdir -p $B
SRC="rtl/common/ttg_first_set.sv rtl/common/ttg_onehot_mux.sv rtl/backend/tlb_mmu/tlb_mmu_pkg.sv tests/tlb_par/tlb_ref_pkg.sv
     rtl/backend/tlb_mmu/tlb_mmu_store.sv rtl/backend/tlb_mmu/tlb_mmu_early.sv rtl/backend/tlb_mmu/tlb_mmu_lookup.sv
     rtl/backend/tlb_mmu/tlb_mmu_lane.sv rtl/backend/tlb_mmu/tlb_mmu_core.sv
     tests/tlb_par/tlb_mmu_lane_ref.sv tests/tlb_par/tlb_mmu_core_ref.sv tests/tlb_par/tlb_par_tb.sv"
verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style --top-module tlb_par_tb rtl/common/ttg_cfg_pkg.sv $SRC \
  -Mdir $B/obj >$B/build.log 2>&1 || { tail -30 $B/build.log; exit 1; }
$B/obj/Vtlb_par_tb +cycles=$N +verilator+seed+$RANDOM +verilator+rand+reset+2
