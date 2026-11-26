# Directed SoC PLIC + external ext_irq[6:0] + S-mode seip test (runs on chip_top via soc_tb):
#   Phase A (M-mode Context 0):
#     - Configure external IRQ pins: src3 (ext_irq[1]) prio=2, src6 (ext_irq[4]) prio=5, src8 (ext_irq[6]) prio=1
#     - Set threshold_ctx0 = 1 (masks src8!), assert ext_irq = 0x52 (src3, src6, src8 simultaneously)
#     - Verify claim order is strictly 6 -> 3, and src8 is masked while threshold=1
#     - Lower threshold_ctx0 = 0 -> verify src8 is claimed next (exact order 6, 3, 8)
#     - Deassert ext_irq, complete all 3 IDs, verify pending == 0
#   Phase B (S-mode Context 1 / seip):
#     - Delegate SEIP (mideleg = 1<<9), configure stvec, PLIC Context 1 enable=(1<<5) prio[5]=4
#     - Drop to S-mode via mret, assert ext_irq = 0x08 (src5 = ext_irq[3])
#     - Verify S-mode trap taken with scause = 0x8000_0000_0000_0009, claim_ctx1 == 5, complete
#     - Print "[SOC_PLIC:PASS]\n"
.section .text.start, "ax"
.globl _start
_start:
  li   s0, 0x0C000000             # PLIC_BASE
  li   s1, 0                      # trap count
  li   s2, 0                      # packed claim log: byte0=1st, byte1=2nd, byte2=3rd

  # ---- Phase A: M-mode multi-source priority + threshold ----
  la   t0, m_trap_handler
  csrw mtvec, t0

  # priority[3]=2 (+0x0C), priority[6]=5 (+0x18), priority[8]=1 (+0x20)
  li   t0, 2
  sw   t0, 0x0C(s0)
  li   t0, 5
  sw   t0, 0x18(s0)
  li   t0, 1
  sw   t0, 0x20(s0)

  # enable_ctx0 = (1<<3) | (1<<6) | (1<<8) = 0x148 @ +0x2000
  li   t1, 0x2000
  add  t1, s0, t1
  li   t0, (1 << 3) | (1 << 6) | (1 << 8)
  sw   t0, 0(t1)

  # threshold_ctx0 = 1 @ +0x200000 (masks src8 with prio=1)
  li   s3, 0x200000
  add  s3, s0, s3                 # s3 = PLIC ctx0 threshold (+4 = claim/complete)
  li   t0, 1
  sw   t0, 0(s3)

  # Trigger soc_tb to drive ext_irq = 0x52 (bits 1, 4, 6 -> PLIC src 3, 6, 8)
  la   a0, msg_m_go
  call uart_puts

  # Wait until PLIC pending (+0x1000) shows all 3 sources asserted
  li   t1, 0x1000
  add  t1, s0, t1
  li   t2, (1 << 3) | (1 << 6) | (1 << 8)
wait_pend3:
  lw   t0, 0(t1)
  and  t0, t0, t2
  bne  t0, t2, wait_pend3

  # Enable MEIE (bit 11) and MSTATUS.MIE (bit 3)
  li   t0, (1 << 11)
  csrw mie, t0
  csrs mstatus, 8

  # Wait for first 2 traps (src6 then src3)
wait_two:
  li   t0, 2
  blt  s1, t0, wait_two

  # Delay ~32 cycles to verify src8 (prio=1 <= threshold=1) does NOT fire!
  li   t0, 32
mask_check:
  addi t0, t0, -1
  bnez t0, mask_check
  li   t0, 2
  bne  s1, t0, fail

  # Now lower threshold_ctx0 = 0 so src8 (prio=1) fires!
  sw   zero, 0(s3)
wait_three:
  li   t0, 3
  blt  s1, t0, wait_three

  # Disable M-mode IRQ, ask soc_tb to clear ext_irq = 0x00
  csrci mstatus, 8
  csrw mie, zero
  la   a0, msg_m_clr
  call uart_puts

  # Wait for ext_irq pins to drop (complete all 3, then check pending == 0)
  li   t0, 6
  sw   t0, 4(s3)
  li   t0, 3
  sw   t0, 4(s3)
  li   t0, 8
  sw   t0, 4(s3)

  li   t1, 0x1000
  add  t1, s0, t1
wait_clr_m:
  lw   t0, 0(t1)
  bnez t0, wait_clr_m

  # Verify exact claim order: 6 (byte0), 3 (byte1), 8 (byte2) -> 0x00080306
  li   t0, 0x00080306
  bne  s2, t0, fail

  # ---- Phase B: S-mode seip via PLIC Context 1 ----
  # Disable Context 0, enable Context 1 for src5 (ext_irq[3]), prio[5]=4, threshold_ctx1=0
  li   t1, 0x2000
  add  t1, s0, t1
  sw   zero, 0(t1)                # enable_ctx0 = 0
  li   t0, 4
  sw   t0, 0x14(s0)               # priority[5] = 4
  li   t1, 0x2080
  add  t1, s0, t1
  li   t0, (1 << 5)
  sw   t0, 0(t1)                  # enable_ctx1 = (1 << 5)
  li   s4, 0x201000
  add  s4, s0, s4                 # s4 = PLIC ctx1 threshold (+4 = claim/complete)
  sw   zero, 0(s4)                # threshold_ctx1 = 0

  # Delegate SEIP (bit 9) to S-mode, setup stvec, sie.SEIE, satp=0 (Bare)
  li   t0, (1 << 9)
  csrw mideleg, t0
  csrw mie, t0                    # also visible via sie since delegated
  csrw satp, zero
  la   t0, s_trap_handler
  csrw stvec, t0
  li   s5, 0                      # S-mode claimed ID

  # Enter S-mode via mret with SIE=0 first; enable sstatus.SIE after uart_puts finishes
  li   t0, (1 << 11)              # MPP=S, SIE=0, MPIE=0
  csrw mstatus, t0
  la   t0, s_mode_entry
  csrw mepc, t0
  mret

.balign 4
s_mode_entry:
  # Ask soc_tb to assert ext_irq = 0x08 (bit 3 -> PLIC src5)
  la   a0, msg_s_go
  call uart_puts

  # Now enable S-mode interrupts (sstatus.SIE = bit 1)
  csrsi sstatus, 2

wait_seip:
  beqz s5, wait_seip

  # Disable sstatus.SIE, verify claimed ID == 5
  csrci sstatus, 2
  li   t0, 5
  bne  s5, t0, fail

  # Ask soc_tb to clear ext_irq = 0x00, complete src5 on Context 1
  la   a0, msg_s_clr
  call uart_puts
  li   t0, 5
  sw   t0, 4(s4)

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
  andi t2, t2, 0x20
  beqz t2, 2b
  sb   t1, 0(t0)
  addi a0, a0, 1
  j    1b
3:
  lbu  t2, 5(t0)
  andi t2, t2, 0x40
  beqz t2, 3b
  ret

.balign 4
m_trap_handler:
  csrr t4, mcause
  li   t5, 0x800000000000000B     # M-external interrupt
  bne  t4, t5, fail
  lw   t5, 4(s3)                  # claim_ctx0 (leave claimed so next priority wins)
  beqz t5, fail
  slli t6, s1, 3                  # shift = count * 8
  sll  t5, t5, t6
  or   s2, s2, t5
  addi s1, s1, 1
  mret

.balign 4
s_trap_handler:
  csrr t4, scause
  li   t5, 0x8000000000000009     # S-external interrupt
  bne  t4, t5, fail
  lw   s5, 4(s4)                  # claim_ctx1 (leave claimed until ext_irq clears)
  beqz s5, fail
  sret

.section .rodata
msg_m_go:
  .asciz "[PLIC_M_GO]\n"
msg_m_clr:
  .asciz "[PLIC_M_CLR]\n"
msg_s_go:
  .asciz "[PLIC_S_GO]\n"
msg_s_clr:
  .asciz "[PLIC_S_CLR]\n"
msg_pass:
  .asciz "[SOC_PLIC:PASS]\n"
msg_fail:
  .asciz "[SOC_PLIC:FAIL]\n"
