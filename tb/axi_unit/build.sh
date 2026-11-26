#!/usr/bin/env bash
# Build and run the standalone AXI4 Protocol & Stress Unit Testbench (tb/axi_unit).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${AXI_UNIT_OUT:-$ROOT/build/axi_unit}; mkdir -p "$OUT"
DDR_DATA_W=${DDR_DATA_W:-64}

PKGS=(
  "$ROOT/rtl/soc/soc_axi/soc_axi_pkg.sv"
  "$ROOT/rtl/soc/soc_pkg/soc_pkg.sv"
)
SRCS=(
  "$ROOT/rtl/common/sram/ttg_sram_1rw.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_skid.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_reg_slice.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_checker.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_downsizer_rd.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_downsizer.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_xbar_rd.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_xbar_wr.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_xbar.sv"
  "$ROOT/rtl/soc/soc_axi/soc_axi_to_lite.sv"
  "$ROOT/rtl/soc/soc_xbar/soc_xbar_sys.sv"
  "$ROOT/rtl/soc/soc_xbar/soc_xbar.sv"
  "$ROOT/rtl/soc/soc_bootrom/soc_bootrom.sv"
  "$ROOT/rtl/soc/soc_sram/soc_sram.sv"
  "$ROOT/rtl/soc/soc_clint/soc_clint.sv"
  "$ROOT/rtl/soc/soc_plic/soc_plic.sv"
  "$ROOT/rtl/soc/soc_uart/soc_uart_tx.sv"
  "$ROOT/rtl/soc/soc_uart/soc_uart_rx.sv"
  "$ROOT/rtl/soc/soc_uart/soc_uart.sv"
  "$ROOT/rtl/soc/soc_sysctrl/soc_sysctrl.sv"
  "$ROOT/tb/axi_unit/axi_unit_top.sv"
)

cd "$OUT"
verilator --cc --exe --build -j 8 --assert -Wall -Wno-DECLFILENAME \
  -GDDR_DATA_W="$DDR_DATA_W" \
  --top-module axi_unit_top -Mdir obj \
  -CFLAGS "-O2 -std=c++20" \
  "$ROOT/tb/axi_unit/axi_unit_tb.cpp" "${PKGS[@]}" "${SRCS[@]}" -o axi_unit_tb > build.log 2>&1 || {
    cat build.log | tail -40
    exit 1
  }
"$OUT/obj/axi_unit_tb"
