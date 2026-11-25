/* Directed test: High-frequency M-mode timer interrupts racing with branch mispredicts, loads/stores, and LR/SC.
 * Drives >= 40 asynchronous timer interrupts (raising sva_rob c_rob_irq coverage from 5 -> 45+).
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    li   s0, 0x1fd0e000         /* TIMER_LOW */
    li   s1, 0x1fd0e008         /* TIMER_CMP */
    li   s2, 0x80020000         /* scratch RAM */
    li   s10, 40                /* target IRQ count */
    li   s11, 0                 /* actual IRQ count */
    li   s3, 0xace1             /* LFSR state for mispredicts */
    li   s4, 0                  /* accumulator */
    sd   zero, 0(s2)

    /* Install M-mode trap handler */
    la   t0, irq_handler
    csrw mtvec, t0

    /* Arm first timer interrupt: mtime + 50 */
    ld   t0, 0(s0)
    addi t0, t0, 50
    sd   t0, 0(s1)

    /* Enable MTIE (bit 7 in mie) and MIE (bit 3 in mstatus) */
    li   t0, (1 << 7)
    csrs mie, t0
    li   t0, (1 << 3)
    csrs mstatus, t0

    /* Stress loop: pseudo-random branches + loads/stores + lr.d/sc.d until >= 40 IRQs delivered */
work_loop:
    /* 16-bit Galois LFSR step -> unpredictable branch */
    andi t1, s3, 1
    srli s3, s3, 1
    beqz t1, br_even
    li   t2, 0xb400
    xor  s3, s3, t2
    addi s4, s4, 3
    j    br_join
br_even:
    addi s4, s4, 1
br_join:
    /* Memory traffic + atomic AMO (Note: LR/SC across an async IRQ exposes R-7: speculative SC clears RTL rsv_valid_q before flush while FM keeps reserve_valid) */
    sd   s4, 8(s2)
    ld   t3, 8(s2)
    bne  t3, s4, fail
    li   t4, 1
    amoadd.d t5, t4, (s2)
    bltu s11, s10, work_loop

    /* Disable interrupts and park comparator */
    li   t0, (1 << 3)
    csrc mstatus, t0
    li   t0, -1
    sd   t0, 0(s1)

    /* Sanity check: at least 40 IRQs taken */
    bltu s11, s10, fail

    li   a0, 0
    ebreak

irq_handler:
    csrr t6, mcause
    /* Must be M-mode timer interrupt: MSB=1, code=7 */
    li   a7, (1 << 63) | 7
    bne  t6, a7, fail
    addi s11, s11, 1
    bgeu s11, s10, park_timer
    ld   t6, 0(s0)
    addi t6, t6, 50
    sd   t6, 0(s1)
    mret
park_timer:
    li   t6, -1
    sd   t6, 0(s1)
    mret

fail:
    j    fail
