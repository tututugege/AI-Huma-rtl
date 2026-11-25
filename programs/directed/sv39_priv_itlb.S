/* Directed test: True S-mode Sv39 SUM/MXR permissions + SFENCE.VMA ITLB invalidation.
 *   - Enters S-mode via mret with Sv39 active.
 *   - Verifies SUM=0 faults on U-page load (cause 13, mtval=0), SUM=1 succeeds.
 *   - Verifies MXR=0 faults on X-only page load (cause 13, mtval=0x1000), MXR=1 succeeds.
 *   - Calls VA 0x2000 (stub A -> returns 0x111), remaps PTE to stub B (returns 0x222),
 *     executes sfence.vma, calls VA 0x2000 again -> must return 0x222 (proves ITLB flushed).
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

    /* root[2] = 1GB identity leaf 0x80000000 -> 0x80000000 (V R W X A D = 0xcf) */
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

    /* L0[0]: VA 0x0000 -> PA 0x80020000, User page (V R W X U A D = 0xdf) */
    li   t0, 0x80012000
    li   t1, (0x80020 << 10) | 0xdf
    sd   t1, 0(t0)
    li   t2, 0x80020000
    li   t3, 0x1111222233334444
    sd   t3, 0(t2)

    /* L0[1]: VA 0x1000 -> PA 0x80021000, Exec-only page (V X A D = 0xc9) */
    li   t0, 0x80012008
    li   t1, (0x80021 << 10) | 0xc9
    sd   t1, 0(t0)
    li   t2, 0x80021000
    li   t3, 0x5555666677778888
    sd   t3, 0(t2)

    /* L0[2]: VA 0x2000 -> PA 0x80022000 (stub A), V R W X A D = 0xcf */
    li   t0, 0x80012010
    li   t1, (0x80022 << 10) | 0xcf
    sd   t1, 0(t0)

    /* Populate stub A at PA 0x80022000: addi a0, zero, 0x111; ret */
    li   t2, 0x80022000
    li   t3, 0x11100513         /* addi a0, x0, 0x111 */
    sw   t3, 0(t2)
    li   t3, 0x00008067         /* jalr x0, 0(ra) */
    sw   t3, 4(t2)

    /* Populate stub B at PA 0x80023000: addi a0, zero, 0x222; ret */
    li   t2, 0x80023000
    li   t3, 0x22200513         /* addi a0, x0, 0x222 */
    sw   t3, 0(t2)
    li   t3, 0x00008067         /* jalr x0, 0(ra) */
    sw   t3, 4(t2)
    fence.i

    /* Install M-mode trap handler, keep medeleg=0 */
    la   t0, m_trap
    csrw mtvec, t0
    csrw medeleg, zero

    /* Enable Sv39 */
    li   t0, (8 << 60) | 0x80010
    csrw satp, t0
    sfence.vma

    /* Drop to S-mode at s_entry (MPP = 1, SUM = 0, MXR = 0) */
    li   t0, (3 << 11) | (1 << 18) | (1 << 19)
    csrc mstatus, t0
    li   t0, (1 << 11)
    csrs mstatus, t0
    la   t0, s_entry
    csrw mepc, t0
    li   s1, 0                  /* fault counter */
    mret

s_entry:
    /* 1. SUM=0: load from U-page VA 0x0000 -> must fault (cause 13, tval 0) */
    li   s2, 13
    li   s3, 0x0000
    ld   t0, 0(s3)
    li   t1, 1
    bne  s1, t1, fail

    /* 2. SUM=1: load from U-page VA 0x0000 -> must succeed */
    li   t0, (1 << 18)          /* sstatus.SUM */
    csrs sstatus, t0
    ld   t0, 0(s3)
    li   t1, 0x1111222233334444
    bne  t0, t1, fail

    /* 3. MXR=0: load from X-only page VA 0x1000 -> must fault (cause 13, tval 0x1000) */
    li   s2, 13
    li   s3, 0x1000
    ld   t0, 0(s3)
    li   t1, 2
    bne  s1, t1, fail

    /* 4. MXR=1: load from X-only page VA 0x1000 -> must succeed */
    li   t0, (1 << 19)          /* sstatus.MXR */
    csrs sstatus, t0
    ld   t0, 0(s3)
    li   t1, 0x5555666677778888
    bne  t0, t1, fail

    /* 5. Call VA 0x2000 (stub A -> 0x111, warms ITLB) */
    li   s4, 0x2000
    jalr ra, 0(s4)
    li   t1, 0x111
    bne  a0, t1, fail

    /* 6. Remap L0[2] (0x80012010) to PA 0x80023000 (stub B), sfence.vma, call VA 0x2000 */
    li   t0, 0x80012010
    li   t1, (0x80023 << 10) | 0xcf
    sd   t1, 0(t0)
    sfence.vma
    jalr ra, 0(s4)
    li   t1, 0x222
    bne  a0, t1, fail

    /* 7. Return to M-mode via S-mode ecall (cause 9) */
    li   s2, 9
    ecall
    j    fail

m_trap:
    csrr t4, mcause
    bne  t4, s2, fail
    li   t5, 9
    beq  t4, t5, done_ok
    csrr t5, mtval
    bne  t5, s3, fail
    addi s1, s1, 1
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

done_ok:
    csrw satp, zero
    sfence.vma
    li   a0, 0
    ebreak

fail:
    j    fail
