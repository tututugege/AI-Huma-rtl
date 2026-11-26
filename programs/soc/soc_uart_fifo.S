# Directed SoC UART test (runs on chip_top via soc_tb):
#   1. Program non-1 baud divisor (DLL=2, DLM=0 -> 32 core cycles/bit) + test SCR & FCR FIFO clear
#   2. Print "[UART_RDY]\n" so soc_tb drives 17 serial bytes into external chip_top.uart_rxd pin
#   3. Receive & verify all 17 bytes from external uart_rxd via RBR / LSR.DR
#   4. Burst-write 16 bytes back-to-back into 16B TX FIFO without polling THRE, verify LSR.THRE==0
#      & LSR.TEMT==0 while draining, then wait THRE and stream 10 more bytes ("0123456789ABCDEFGHIJKLMNOP")
#   5. Print "[SOC_UART:PASS]\n" at divisor=2
.section .text.start, "ax"
.globl _start
_start:
  li   s0, 0x10000000             # UART_BASE

  # ---- 1. Test SCR scratch register + program DLL=2, DLM=0 ----
  li   t0, 0xA5
  sb   t0, 7(s0)                  # SCR = 0xA5
  lbu  t1, 7(s0)
  bne  t0, t1, fail

  li   t0, 0x83                   # LCR: DLAB=1, 8N1
  sb   t0, 3(s0)
  li   t0, 0x02                   # DLL = 2 (32 cycles/bit)
  sb   t0, 0(s0)
  sb   zero, 1(s0)                # DLM = 0
  # Readback DLL & DLM while DLAB=1
  lbu  t1, 0(s0)
  li   t0, 0x02
  bne  t1, t0, fail
  lbu  t1, 1(s0)
  bne  t1, zero, fail
  li   t0, 0x03                   # LCR: DLAB=0, 8N1
  sb   t0, 3(s0)
  li   t0, 0x06                   # FCR: clear RX & TX FIFOs
  sb   t0, 2(s0)

  # ---- 2. Announce ready so soc_tb injects 17 bytes on external uart_rxd ----
  la   a0, msg_rdy
  call uart_puts

  # ---- 3. Receive & verify 17 bytes from external uart_rxd pin ----
  la   s1, exp_rx
  li   s2, 17
rx_loop:
  lbu  t0, 5(s0)                  # LSR
  andi t0, t0, 0x01               # LSR.DR
  beqz t0, rx_loop
  lbu  t1, 0(s0)                  # RBR
  lbu  t2, 0(s1)
  bne  t1, t2, fail
  addi s1, s1, 1
  addi s2, s2, -1
  bnez s2, rx_loop

  # Verify RX FIFO is now empty (LSR.DR == 0)
  lbu  t0, 5(s0)
  andi t0, t0, 0x01
  bnez t0, fail

  # ---- 4. Fill 16B TX FIFO back-to-back without polling THRE ----
  # First ensure TX is completely idle (TEMT=1)
wait_idle:
  lbu  t0, 5(s0)
  andi t0, t0, 0x40
  beqz t0, wait_idle

  la   s1, tx_burst
  li   s2, 16
burst16:
  lbu  t1, 0(s1)
  sb   t1, 0(s0)                  # back-to-back THR push into 16B FIFO
  addi s1, s1, 1
  addi s2, s2, -1
  bnez s2, burst16

  # TX FIFO must currently be non-empty (LSR.THRE == 0 and LSR.TEMT == 0)
  lbu  t0, 5(s0)
  andi t1, t0, 0x60               # THRE | TEMT
  bnez t1, fail

  # Wait until TX FIFO drains (LSR.THRE == 1), then push remaining 10 bytes
wait_thre:
  lbu  t0, 5(s0)
  andi t0, t0, 0x20
  beqz t0, wait_thre

  li   s2, 10
burst10:
  lbu  t1, 0(s1)
  sb   t1, 0(s0)
  addi s1, s1, 1
  addi s2, s2, -1
  bnez s2, burst10

  # ---- 5. Print PASS banner ----
  la   a0, msg_pass
  call uart_puts
  j    done_spin

fail:
  la   a0, msg_fail
  call uart_puts
done_spin:
  j    done_spin

uart_puts:
  li   t0, 0x10000000
1:
  lbu  t1, 0(a0)
  beqz t1, 3f
2:
  lbu  t2, 5(t0)
  andi t2, t2, 0x20               # THRE
  beqz t2, 2b
  sb   t1, 0(t0)
  addi a0, a0, 1
  j    1b
3:
  lbu  t2, 5(t0)
  andi t2, t2, 0x40               # TEMT
  beqz t2, 3b
  ret

.section .rodata
msg_rdy:
  .asciz "[UART_RDY]\n"
exp_rx:
  .ascii "0123456789ABCDEF!"
tx_burst:
  .ascii "0123456789ABCDEFGHIJKLMNOP"
msg_pass:
  .asciz "\n[SOC_UART:PASS]\n"
msg_fail:
  .asciz "\n[SOC_UART:FAIL]\n"
