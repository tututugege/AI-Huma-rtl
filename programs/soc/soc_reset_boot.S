# Directed SoC Soft Reset (SysCtrl.RST_CTL) + CRG Recovery + boot_mode=2'b01 SRAM Boot test:
#   Boot 1 (boot_mode=2'b00, DDR boot):
#     1. Verify BOOT_STAT == 0 and write non-zero sentinel into SysCtrl.SCRATCH0
#     2. Copy position-independent RV64 payload into On-Chip SRAM @ 0x3000_0000 (uncached -> SRAM array)
#     3. Print "[SOC_SW_RST:GO]\n" (wait LSR.TEMT) so soc_tb switches boot_mode pin to 2'b01
#     4. Write 0x5A5A_0001 to SysCtrl.RST_CTL (0x1F00_0010) to fire hardware sw_rst_req -> soc_crg
#   Boot 2 (boot_mode=2'b01, On-Chip SRAM boot via real BootROM, zero TB backdoor):
#     5. BootROM reads BOOT_STAT == 1 and jumps directly to 0x3000_0000 (SRAM survived reset!)
#     6. SRAM payload verifies a0==0, BOOT_STAT==1, SCRATCH0==0 (proving SysCtrl actually reset!),
#        and prints "[SOC_SRAM_BOOT:PASS]\n" over real serial uart_txd
.section .text.start, "ax"
.globl _start
_start:
  li   s0, 0x1F000000             # SYSCTRL_BASE
  ld   t0, 0x08(s0)               # BOOT_STAT must be 0 on Boot 1
  bnez t0, ddr_fail

  # Write sentinel into SCRATCH0 (must reset to 0 after sw_rst_req)
  li   t0, 0xCAFEBABE12345678
  sd   t0, 0x20(s0)
  ld   t1, 0x20(s0)
  bne  t0, t1, ddr_fail

  # Copy position-independent SRAM boot payload to 0x3000_0000
  la   t0, sram_boot_code
  la   t1, sram_boot_end
  li   t2, 0x30000000
copy_loop:
  ld   t3, 0(t0)
  sd   t3, 0(t2)
  addi t0, t0, 8
  addi t2, t2, 8
  bltu t0, t1, copy_loop
  fence

  # Tell soc_tb to switch boot_mode strap pin to 2'b01 before triggering sw_rst_req
  la   a0, msg_go
  call ddr_uart_puts

  # Small settle delay so boot_mode pin update is guaranteed before reset fires
  li   t0, 64
settle:
  addi t0, t0, -1
  bnez t0, settle

  # Fire hardware software reset via SysCtrl.RST_CTL (+0x10) = 0x5A5A_0001
  li   t0, 0x5A5A0001
  sw   t0, 0x10(s0)

  # Should reset within a few cycles; spin safely while reset takes effect
spin_rst:
  j    spin_rst

ddr_fail:
  la   a0, msg_ddr_fail
  call ddr_uart_puts
1:
  j    1b

ddr_uart_puts:
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

# ==============================================================================
# Position-independent SRAM boot payload (copied verbatim to 0x3000_0000)
# ==============================================================================
.balign 8
sram_boot_code:
  # 1. BootROM passes a0 = mhartid (0)
  bnez a0, sram_fail

  # 2. Verify PC is actually executing inside On-Chip SRAM (0x3000_0000..0x3000_FFFF)
  auipc t0, 0
  srli  t0, t0, 16
  li    t1, 0x3000
  bne   t0, t1, sram_fail

  # 3. Verify SysCtrl.BOOT_STAT == 1 and SCRATCH0 == 0 (hardware reset occurred!)
  li    s0, 0x1F000000
  ld    t0, 0x08(s0)              # BOOT_STAT
  li    t1, 1
  bne   t0, t1, sram_fail
  ld    t0, 0x20(s0)              # SCRATCH0 (was 0xCAFEBABE12345678 before reset)
  bnez  t0, sram_fail

  # 4. Print PASS banner directly from SRAM
  la    a0, sram_msg_pass
  jal   ra, sram_uart_puts
  j     sram_spin

sram_fail:
  la    a0, sram_msg_fail
  jal   ra, sram_uart_puts
sram_spin:
  j     sram_spin

sram_uart_puts:
  li    t0, 0x10000000
1:
  lbu   t1, 0(a0)
  beqz  t1, 3f
2:
  lbu   t2, 5(t0)
  andi  t2, t2, 0x20
  beqz  t2, 2b
  sb    t1, 0(t0)
  addi  a0, a0, 1
  j     1b
3:
  lbu   t2, 5(t0)
  andi  t2, t2, 0x40
  beqz  t2, 3b
  ret

sram_msg_pass:
  .asciz "[SOC_SRAM_BOOT:PASS]\n"
sram_msg_fail:
  .asciz "[SOC_SRAM_BOOT:FAIL]\n"
.balign 8
sram_boot_end:

.section .rodata
msg_go:
  .asciz "[SOC_SW_RST:GO]\n"
msg_ddr_fail:
  .asciz "[SOC_RESET:FAIL]\n"
