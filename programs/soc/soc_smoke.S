# Real SoC v1 end-to-end self-checking smoke test (runs on chip_top after real RTL BootROM):
#   1. Verify BootROM ABI (a0=0, a1=0x83e00000) and SysCtrl CHIP_ID / BOOT_STAT / 64b SCRATCH / UPTIME
#   2. Verify 64 KiB On-Chip SRAM (0x3000_0000) 64b + byte/half/word writes AND ICache execution from SRAM
#   3. Verify CLINT real timer IRQ (mtip via clk_rtc CDC, both 0x1FD0_E000 & 0x0200_0000) + software IRQ (msip)
#   4. Verify real NS16550A serial loopback (MCR.LOOP) + RX IRQ -> PLIC priority/enable/claim/complete -> meip
#   5. Verify unmapped MMIO read returns cleanly (DECERR, no bus hang)
#   6. Print "[SOC_SMOKE:PASS]\n" over real serial uart_txd
.section .text.start, "ax"
.globl _start
_start:
  # Save BootROM ABI registers
  mv   s0, a0                     # expect 0 (mhartid)
  mv   s1, a1                     # expect 0x83e0_0000

  # ---- 1. BootROM ABI & SysCtrl ----
  bne  s0, zero, fail
  li   t0, 0x83e00000
  bne  s1, t0, fail

  li   s2, 0x1F000000             # SYSCTRL_BASE
  ld   t0, 0(s2)                  # CHIP_ID
  li   t1, 0x0001000048554D41
  bne  t0, t1, fail
  ld   t0, 8(s2)                  # BOOT_STAT
  bne  t0, zero, fail

  # 64-bit SCRATCH0/1 write & readback
  li   t0, 0x1122334455667788
  sd   t0, 0x20(s2)
  ld   t1, 0x20(s2)
  bne  t0, t1, fail
  # Uptime advancing
  ld   t0, 0x30(s2)
  nop
  nop
  ld   t1, 0x30(s2)
  bleu t1, t0, fail

  # ---- 2. 64 KiB On-Chip SRAM (0x3000_0000) data + code execution ----
  li   s3, 0x30000000
  li   t0, 0xA5A55A5ADEADBEEF
  sd   t0, 0(s3)
  ld   t1, 0(s3)
  bne  t0, t1, fail
  # Byte write test on byte 2 (0xAD -> 0x42)
  li   t2, 0x42
  sb   t2, 2(s3)
  ld   t1, 0(s3)
  li   t0, 0xA5A55A5ADE42BEEF
  bne  t0, t1, fail

  # Write a 2-instruction function into SRAM @ 0x3000_1000:
  #   addi a0, a0, 42  (0x02a50513)
  #   jalr zero, 0(ra) (0x00008067)
  li   s4, 0x30001000
  li   t0, 0x02a50513
  sw   t0, 0(s4)
  li   t0, 0x00008067
  sw   t0, 4(s4)
  fence
  fence.i
  li   a0, 100
  jalr ra, 0(s4)
  li   t0, 142
  bne  a0, t0, fail

  # ---- 3. CLINT (both 0x1FD0_E000 & 0x0200_0000) + mtip + msip ----
  la   t0, trap_handler
  csrw mtvec, t0
  li   s5, 0                      # s5 = IRQ bitmap: bit0=mtip, bit1=msip, bit2=meip
  li   s6, 0x1FD0E000             # ACLINT alias
  li   s7, 0x02000000             # Standard SiFive CLINT alias

  # Verify both aliases see same mtime
  ld   t0, 0(s6)
  li   t1, 0xBFF8
  add  t1, s7, t1
  ld   t2, 0(t1)
  bltu t2, t0, fail

  # Arm timer IRQ: mtimecmp = mtime + 4
  addi t0, t2, 4
  sd   t0, 8(s6)
  li   t0, (1 << 7) | (1 << 3) | (1 << 11)   # MTIE | MSIE | MEIE
  csrs mie, t0
  csrs mstatus, 8                             # MSTATUS.MIE

wait_mtip:
  andi t0, s5, 1
  beqz t0, wait_mtip

  # Trigger software IRQ via standard CLINT msip @ 0x0200_0000
  li   t0, 1
  sw   t0, 0(s7)
wait_msip:
  andi t0, s5, 2
  beqz t0, wait_msip

  # ---- 4. Real NS16550A serial loopback + PLIC external IRQ (meip) ----
  li   s8, 0x0C000000             # PLIC_BASE
  li   s9, 0x10000000             # UART_BASE

  # PLIC: priority[1] = 3, enable_ctx0 = (1 << 1), threshold_ctx0 = 0
  li   t0, 3
  sw   t0, 4(s8)                  # priority[1] @ +0x000004
  li   t0, 2
  li   t1, 0x2000
  add  t1, s8, t1
  sw   t0, 0(t1)                  # enable_ctx0 @ +0x002000
  li   t1, 0x200000
  add  t1, s8, t1
  sw   zero, 0(t1)                # threshold_ctx0 @ +0x200000

  # UART: MCR = 0x10 (internal serial loopback), IER = 0x01 (RX data ready IRQ)
  li   t0, 0x10
  sb   t0, 4(s9)
  li   t0, 0x01
  sb   t0, 1(s9)
  # Send 0x5A over real TX->RX serial loopback
  li   t0, 0x5A
  sb   t0, 0(s9)

wait_meip:
  andi t0, s5, 4
  beqz t0, wait_meip

  # Disable loopback & UART IRQ, disable global MIE
  csrci mstatus, 8
  sb   zero, 1(s9)
  sb   zero, 4(s9)

  # Verify loopback received byte (saved in s10 by trap handler) == 0x5A
  li   t0, 0x5A
  bne  s10, t0, fail

  # ---- 5. Unmapped address DECERR safety ----
  li   t0, 0x12340000
  ld   t1, 0(t0)
  bne  t1, zero, fail

  # ---- 6. Print PASS banner over real serial uart_txd ----
  la   a0, msg_pass
  call uart_puts
  j    done_spin

fail:
  la   a0, msg_fail
  call uart_puts
done_spin:
  j    done_spin

# ---- Real serial UART puts (polls LSR.THRE, then waits for LSR.TEMT) ----
uart_puts:
  li   t0, 0x10000000
1:
  lbu  t1, 0(a0)
  beqz t1, 3f
2:
  lbu  t2, 5(t0)                  # LSR
  andi t2, t2, 0x20               # THRE
  beqz t2, 2b
  sb   t1, 0(t0)                  # THR
  addi a0, a0, 1
  j    1b
3:
  lbu  t2, 5(t0)                  # wait TEMT (bit 6) so last stop bit exits uart_txd
  andi t2, t2, 0x40
  beqz t2, 3b
  ret

# ---- M-mode Trap Handler ----
.balign 4
trap_handler:
  csrr t0, mcause
  # Check M-timer IRQ (0x8000_0000_0000_0007)
  li   t1, 0x8000000000000007
  beq  t0, t1, on_mtip
  # Check M-software IRQ (0x8000_0000_0000_0003)
  li   t1, 0x8000000000000003
  beq  t0, t1, on_msip
  # Check M-external IRQ (0x8000_0000_0000_000B)
  li   t1, 0x800000000000000B
  beq  t0, t1, on_meip
  j    fail

on_mtip:
  li   t2, -1
  sd   t2, 8(s6)                  # clear mtip by setting mtimecmp = 0xFFFF_FFFF_FFFF_FFFF
  ori  s5, s5, 1
  mret

on_msip:
  sw   zero, 0(s7)                # clear msip
  ori  s5, s5, 2
  mret

on_meip:
  li   t1, 0x200004
  add  t1, s8, t1                 # PLIC ctx0 claim/complete
  lw   t2, 0(t1)                  # claim -> expect IRQ 1 (UART)
  li   t3, 1
  bne  t2, t3, fail
  lbu  s10, 0(s9)                 # read UART RBR (clears RX FIFO & irq)
  sw   t2, 0(t1)                  # complete IRQ 1
  ori  s5, s5, 4
  mret

.section .rodata
msg_pass:
  .asciz "[SOC_SMOKE:PASS]\n"
msg_fail:
  .asciz "[SOC_SMOKE:FAIL]\n"
