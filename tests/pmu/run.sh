#!/usr/bin/env bash
# Random test of rtl/pmu/pmu.sv (+ the mutation check). usage: tests/pmu/run.sh   (from the rtl root)
set -euo pipefail
cd "$(dirname "$0")/../.."
D=build/pmu_tb
rm -rf $D; mkdir -p build
verilator --cc --exe --build -Wall -Wno-fatal -O1 --top-module pmu -GNUM_HPM=8 rtl/pmu/pmu_ev_pkg.sv rtl/pmu/pmu.sv tests/pmu/pmu_tb.cpp -CFLAGS -I$PWD/tests/pmu -Mdir $D > $D.log 2>&1 || { tail -30 $D.log; exit 1; }
$D/Vpmu
if PMU_TB_MUTATE=1 $D/Vpmu > /dev/null; then echo "PMU_TB mutation NOT detected"; exit 1; else echo "PMU_TB mutation detected (expected)"; fi
