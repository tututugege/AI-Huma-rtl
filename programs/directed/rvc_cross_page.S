/* Directed test: 32-bit instruction straddling a 4KB Sv39 page boundary (0x0ffe .. 0x1001).
 *   1. Both pages valid: executes cross-page `addi s5, s5, 7` at VA 0x0ffe and returns -> s5 == 7.
 *   2. Page 1 (VA 0x1000) invalidated + sfence.vma: calling VA 0x0ffe must raise Instruction Page Fault
 *      (mcause == 12) with mepc == 0x0ffe and mtval == 0x1000 (pc + 2, the faulting high halfword).
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    /* Zero page tables 0x80010000 .. 0x80013000 */
    li   t0, 0x80010000
    li   t1, 0x80013000
zero_pt:
    sd   zero, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, zero_pt

    /* root[2] = 1GB identity leaf 0x80000000 -> 0x80000000 (0xcf) */
    li   t0, 0x80010010
    li   t1, (0x80000 << 10) | 0xcf
    sd   t1, 0(t0)

    /* root[0] -> L1 (0x80011000), L1[0] -> L0 (0x80012000) */
    li   t0, 0x80010000
    li   t1, (0x80011 << 10) | 0x01
    sd   t1, 0(t0)
    li   t0, 0x80011000
    li   t1, (0x80012 << 10) | 0x01
    sd   t1, 0(t0)

    /* L0[0]: VA 0x0000 -> PA 0x80020000 (0xcf), L0[1]: VA 0x1000 -> PA 0x80021000 (0xcf) */
    li   t0, 0x80012000
    li   t1, (0x80020 << 10) | 0xcf
    sd   t1, 0(t0)
    li   t0, 0x80012008
    li   t1, (0x80021 << 10) | 0xcf
    sd   t1, 0(t0)

    /* Write cross-page 4B instruction at PA 0x80020ffe (VA 0x0ffe..0x1001):
     *   addi s5, s5, 7  =>  0x007a8a93  (lo16=0x8a93 at 0x80020ffe, hi16=0x007a at 0x80021000)
     * Followed at PA 0x80021002 by ret (jalr x0, 0(ra) => 0x00008067):
     *   lo16=0x8067 at 0x80021002, hi16=0x0000 at 0x80021004
     */
    li   t0, 0x80020ffe
    li   t1, 0x8a93
    sh   t1, 0(t0)
    li   t0, 0x80021000
    li   t1, 0x007a
    sh   t1, 0(t0)
    li   t1, 0x8067
    sh   t1, 2(t0)
    sh   zero, 4(t0)
    fence.i

    /* Install M-mode trap handler */
    la   t0, m_trap
    csrw mtvec, t0
    csrw medeleg, zero

    /* Enable Sv39 */
    li   t0, (8 << 60) | 0x80010
    csrw satp, t0
    sfence.vma

    /* Drop to S-mode at s_entry */
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11)
    csrs mstatus, t0
    la   t0, s_entry
    csrw mepc, t0
    li   s5, 0
    li   s1, 0                  /* fault count */
    mret

s_entry:
    /* 1. Cross-page fetch & execute with both pages valid */
    li   s4, 0x0ffe
    jalr ra, 0(s4)
    li   t0, 7
    bne  s5, t0, fail

    /* 2. Invalidate Page 1 (VA 0x1000) + sfence.vma, then call VA 0x0ffe -> must fault on hi halfword */
    li   t0, 0x80012008
    sd   zero, 0(t0)
    sfence.vma

    jalr ra, 0(s4)
    /* Trap handler redirects mepc back to ra after verifying cause=12, mepc=0x0ffe, mtval=0x1000 */
    li   t0, 1
    bne  s1, t0, fail
    li   t0, 7
    bne  s5, t0, fail           /* faulting instruction must NOT have updated s5 */

    /* Done: return to M-mode via ecall */
    ecall
    j    fail

m_trap:
    csrr t4, mcause
    li   t5, 9                  /* S-mode ecall */
    beq  t4, t5, done_ok
    li   t5, 12                 /* Instruction Page Fault */
    bne  t4, t5, fail
    csrr t5, mepc
    li   t6, 0x0ffe
    bne  t5, t6, fail
    csrr t5, mtval
    li   t6, 0x1000             /* high halfword page (pc + 2) */
    bne  t5, t6, fail
    addi s1, s1, 1
    csrw mepc, ra               /* resume at caller after jalr */
    mret

done_ok:
    csrw satp, zero
    sfence.vma
    li   a0, 0
    ebreak

fail:
    j    fail
