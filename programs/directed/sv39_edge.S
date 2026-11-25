/* Directed test: Sv39 non-canonical virtual addresses (load/store page fault) + MMIO 8/16/32/64-bit widths.
 * Covers:
 *   - tlb_mmu_lane.sv noncanon check (VA bits [63:39] != {25{VA[38]}})
 *   - peripheral_axi_fmt.sv sh / lh / lhu / lwu on TIMER_CMP (0x1fd0e008)
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    /* ---- Part 1: MMIO 8/16/32/64-bit accesses on TIMER_CMP (0x1fd0e008) ---- */
    li   s0, 0x1fd0e008
    li   t0, 0x7ffff000123489ab /* park high word far in the future so no timer IRQ fires */
    sd   t0, 0(s0)

    /* Read back with 16-bit (lhu / lh), 32-bit unsigned (lwu), and 8-bit (lbu / lb) */
    lhu  t2, 0(s0)
    li   t3, 0x89ab
    bne  t2, t3, fail
    lh   t2, 0(s0)
    li   t3, -30293             /* sign-extended 0x89ab */
    bne  t2, t3, fail
    lwu  t2, 0(s0)
    li   t3, 0x123489ab
    bne  t2, t3, fail
    lbu  t2, 0(s0)
    li   t3, 0xab
    bne  t2, t3, fail
    lb   t2, 0(s0)
    li   t3, -85                /* sign-extended 0xab */
    bne  t2, t3, fail

    /* Exercise 16-bit store (sh) and 8-bit store (sb) paths in peripheral_axi_fmt */
    li   t1, 0x5678
    sh   t1, 0(s0)
    li   t1, 0x34
    sb   t1, 0(s0)

    /* Restore TIMER_CMP to ~0 */
    li   t0, -1
    sd   t0, 0(s0)

    /* ---- Part 2: Sv39 non-canonical VA load & store page faults ---- */
    /* Build minimal 1GB identity map at 0x80010000: root[2] -> PA 0x80000000 */
    li   t0, 0x80010000
    li   t1, 0x80011000
zero_pt:
    sd   zero, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, zero_pt

    li   t0, 0x80010010
    li   t1, (0x80000 << 10) | 0xcf   /* 1GB leaf: V R W X A D */
    sd   t1, 0(t0)

    /* Install M-mode trap handler */
    la   t0, trap_handler
    csrw mtvec, t0

    /* Enable Sv39 in satp (mode=8, PPN=0x80010) */
    li   t0, (8 << 60) | 0x80010
    csrw satp, t0
    sfence.vma

    /* Enable MPRV=1 (bit 17), MPP=S (1 << 11) so data accesses use Sv39 */
    li   t0, (1 << 17) | (1 << 11)
    csrs mstatus, t0

    /* Non-canonical VA #1: bit 38 = 1, bits 63:39 = 0 -> Load Page Fault (cause 13) */
    li   s1, 0                  /* trap counter */
    li   s2, 13                 /* expected mcause */
    li   a1, 1
    slli a1, a1, 38             /* 0x0000_0040_0000_0000 */
    ld   t0, 0(a1)
    li   t1, 1
    bne  s1, t1, fail

    /* Non-canonical VA #2: bit 39 = 1, bit 38 = 0 -> Store Page Fault (cause 15) */
    li   s2, 15                 /* expected mcause */
    li   a1, 1
    slli a1, a1, 39             /* 0x0000_0080_0000_0000 */
    sd   t0, 0(a1)
    li   t1, 2
    bne  s1, t1, fail

    /* Disable MPRV and satp */
    li   t0, (1 << 17) | (3 << 11)
    csrc mstatus, t0
    csrw satp, zero
    sfence.vma

    li   a0, 0
    ebreak

trap_handler:
    csrr t4, mcause
    bne  t4, s2, fail
    csrr t5, mtval
    bne  t5, a1, fail
    addi s1, s1, 1
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

fail:
    j    fail
