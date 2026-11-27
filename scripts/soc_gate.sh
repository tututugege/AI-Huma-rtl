#!/usr/bin/env bash
# soc_gate.sh [--linux] [--skip-w128] [--reuse-build] [outdir]
# One-command regression gate for the real tapeout-oriented SoC (chip_top + Real Full-AXI4 + Peripherals):
#   1. Whole-SoC Verilator -Wall lint (scripts/lint_soc.sh)
#   2. Standalone AXI4 fabric unit & random stress test with --assert (tb/axi_unit/build.sh)
#   3. Bare-metal SoC directed test compilation (programs/soc/build.sh)
#   4. chip_top soc_tb (DDR_DATA_W=64, --assert) running all 5 directed SoC tests:
#        - soc_smoke      : BootROM ABI, SysCtrl, SRAM data+ICache exec, CLINT dual-alias + mtip/msip,
#                           UART loopback + PLIC meip, unmapped DECERR
#        - soc_uart_fifo  : non-1 baud divisor (DLL=2), external uart_rxd 17B RX, 16B TX FIFO burst + THRE/TEMT
#        - soc_plic_ext   : external ext_irq[6:0] multi-source priority (6>3>8), threshold masking, S-mode seip (ctx1)
#        - soc_reset_boot : SysCtrl.RST_CTL sw_rst_req -> CRG reset -> boot_mode=01 On-Chip SRAM boot (zero backdoor)
#        - soc_boot_park  : boot_mode=2'b10 BootROM park loop (silent console, 0 AXI4 errors)
#   5. chip_top soc_tb (DDR_DATA_W=128, --assert) smoke check for parameterized AXI4 width conversion
#   6. Optional (--linux): OpenSBI + Linux boot to "Linux version" banner (DDR_DATA_W=64, 8 threads)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"

RUN_LINUX=0
SKIP_W128=0
REUSE_BUILD=0
OUT=""
for a in "$@"; do
  case "$a" in
    --linux)       RUN_LINUX=1 ;;
    --skip-w128)   SKIP_W128=1 ;;
    --reuse-build) REUSE_BUILD=1 ;;
    *)             OUT="$a" ;;
  esac
done
OUT=${OUT:-$ROOT/build/soc_gate}

# Rule (GEMINI.md §3): delete stale outputs before running; decide pass/fail strictly by exit code.
rm -rf "$OUT/logs" "$OUT/summary.txt"
mkdir -p "$OUT/logs"

PASS=0
FAIL=0
record() {
  local name=$1 rc=$2 log=$3
  local errs
  errs=$(grep -cE "%Error|Assertion failed|\[AXI4_CHK\]" "$log" 2>/dev/null || true)
  if [ "$rc" = 0 ] && [ "$errs" = 0 ]; then
    echo "PASS  $name" | tee -a "$OUT/summary.txt"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name (rc=$rc axi_or_sva_err=$errs, see $log)" | tee -a "$OUT/summary.txt"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== [1/6] Whole-SoC Verilator -Wall lint (lint_soc.sh) ==="
bash "$ROOT/scripts/lint_soc.sh" "$OUT/logs/lint_soc.log" > "$OUT/logs/lint_soc_step.log" 2>&1
rc=$?; cat "$OUT/logs/lint_soc_step.log"
record "lint_soc" "$rc" "$OUT/logs/lint_soc_step.log"

echo "=== [2/6] Standalone AXI4 unit + random stress test (tb/axi_unit) ==="
AXI_OUT="$OUT/axi_unit" bash "$ROOT/tb/axi_unit/build.sh" > "$OUT/logs/axi_unit.log" 2>&1
rc=$?; tail -n 10 "$OUT/logs/axi_unit.log"
record "axi_unit" "$rc" "$OUT/logs/axi_unit.log"

echo "=== [3/6] Build directed SoC bare-metal test programs ==="
bash "$ROOT/programs/soc/build.sh" > "$OUT/logs/progs.log" 2>&1
rc=$?; cat "$OUT/logs/progs.log"
record "soc_progs_build" "$rc" "$OUT/logs/progs.log"

echo "=== [4/6] Build & run soc_tb (chip_top, DDR_DATA_W=64, --assert) ==="
TB64_DIR="$OUT/soc64"
TB64="$TB64_DIR/obj/soc_tb"
if [ "$REUSE_BUILD" = 1 ] && [ -x "$TB64" ]; then
  echo "reusing $TB64" > "$OUT/logs/build_soc64.log"
  record "build_soc64 (reused)" 0 "$OUT/logs/build_soc64.log"
else
  DDR_DATA_W=64 SOC_OUT="$TB64_DIR" SOC_VOPT="${SOC_VOPT:---threads 8}" bash "$ROOT/tb/soc/build.sh" > "$OUT/logs/build_soc64.log" 2>&1
  rc=$?; tail -n 5 "$OUT/logs/build_soc64.log"
  record "build_soc64" "$rc" "$OUT/logs/build_soc64.log"
fi

if [ -x "$TB64" ]; then
  "$TB64" "$ROOT/programs/soc/soc_smoke.bin" \
    --max-cycles 200000 --stop-str "[SOC_SMOKE:PASS]" \
    > "$OUT/logs/soc_smoke.log" 2>&1
  record "soc_smoke (w64)" "$?" "$OUT/logs/soc_smoke.log"

  "$TB64" "$ROOT/programs/soc/soc_uart_fifo.bin" \
    --max-cycles 400000 --uart-div 2 \
    --uart-rx-on-str "[UART_RDY]" --uart-rx "0123456789ABCDEF!" \
    --expect-str "0123456789ABCDEFGHIJKLMNOP" \
    --stop-str "[SOC_UART:PASS]" \
    > "$OUT/logs/soc_uart_fifo.log" 2>&1
  record "soc_uart_fifo (w64, div=2, ext_rxd+16B_fifo)" "$?" "$OUT/logs/soc_uart_fifo.log"

  "$TB64" "$ROOT/programs/soc/soc_plic_ext.bin" \
    --max-cycles 400000 \
    --ext-irq-on-str "[PLIC_M_GO]:0x52" \
    --ext-irq-on-str "[PLIC_M_CLR]:0x00" \
    --ext-irq-on-str "[PLIC_S_GO]:0x08" \
    --ext-irq-on-str "[PLIC_S_CLR]:0x00" \
    --stop-str "[SOC_PLIC:PASS]" \
    > "$OUT/logs/soc_plic_ext.log" 2>&1
  record "soc_plic_ext (w64, ext_irq prio+S-mode seip)" "$?" "$OUT/logs/soc_plic_ext.log"

  "$TB64" "$ROOT/programs/soc/soc_reset_boot.bin" \
    --max-cycles 400000 --boot-mode 0 \
    --boot-mode-on-str "[SOC_SW_RST:GO]:1" \
    --stop-str "[SOC_SRAM_BOOT:PASS]" \
    > "$OUT/logs/soc_reset_boot.log" 2>&1
  record "soc_reset_boot (w64, sw_rst_req->boot_mode=01 SRAM)" "$?" "$OUT/logs/soc_reset_boot.log"

  "$TB64" "$ROOT/programs/soc/soc_smoke.bin" \
    --max-cycles 20000 --boot-mode 2 --expect-silent \
    > "$OUT/logs/soc_boot_park.log" 2>&1
  record "soc_boot_park (w64, boot_mode=10 silent wfi)" "$?" "$OUT/logs/soc_boot_park.log"
fi

if [ "$SKIP_W128" = 0 ]; then
  echo "=== [5/6] Build & run soc_tb (chip_top, DDR_DATA_W=128, --assert) ==="
  TB128_DIR="$OUT/soc128"
  TB128="$TB128_DIR/obj/soc_tb"
  if [ "$REUSE_BUILD" = 1 ] && [ -x "$TB128" ]; then
    echo "reusing $TB128" > "$OUT/logs/build_soc128.log"
    record "build_soc128 (reused)" 0 "$OUT/logs/build_soc128.log"
  else
    DDR_DATA_W=128 SOC_OUT="$TB128_DIR" SOC_VOPT="${SOC_VOPT:---threads 8}" bash "$ROOT/tb/soc/build.sh" > "$OUT/logs/build_soc128.log" 2>&1
    rc=$?; tail -n 5 "$OUT/logs/build_soc128.log"
    record "build_soc128" "$rc" "$OUT/logs/build_soc128.log"
  fi

  if [ -x "$TB128" ]; then
    "$TB128" "$ROOT/programs/soc/soc_smoke.bin" \
      --max-cycles 200000 --stop-str "[SOC_SMOKE:PASS]" \
      > "$OUT/logs/soc_smoke_w128.log" 2>&1
    record "soc_smoke (w128)" "$?" "$OUT/logs/soc_smoke_w128.log"
  fi
fi

if [ "$RUN_LINUX" = 1 ]; then
  LINUX_IMG=${LINUX_IMG:-$HOME/rv64spec/linux_j.bin}
  echo "=== [6/6] Optional Linux boot check ($LINUX_IMG -> Linux version) ==="
  if [ -x "$TB64" ] && [ -f "$LINUX_IMG" ]; then
    "$TB64" "$LINUX_IMG" \
      --max-cycles 3000000 --stop-str "Linux version" --fail-str "" \
      > "$OUT/logs/soc_linux.log" 2>&1
    record "soc_linux (w64, OpenSBI->Linux version)" "$?" "$OUT/logs/soc_linux.log"
  else
    echo "FAIL  soc_linux (missing $TB64 or $LINUX_IMG)" | tee -a "$OUT/summary.txt"
    FAIL=$((FAIL + 1))
  fi
fi

echo "============================================================"
echo "SOC_GATE SUMMARY: PASS=$PASS  FAIL=$FAIL  (logs: $OUT/logs)"
[ "$FAIL" = 0 ]
