/* Directed test of the WRITE-BACK OF A FAULTING LOAD: a load that page-faults on a mispredicted (wrong) path does not write its destination register,
 * so the load that uses it as base never issues.  An implementation that writes the fault address into rd (the old RTL) lets that second load run at
 * the fault address; the trace-model (facts of the function model) would run it at the old register value: the two touch different memory lines, which
 * shows in the cycles of the later correct-path load of the line.
 *   - paging: M mode with MPRV=1, MPP=S, satp = Sv39 (rv64) / Sv32 (rv32) with ONE leaf (a giga / mega page) that maps 0x80000000.. 1:1; everything
 *     else (the NULL page) is unmapped, so a load from 0x20 page-faults.
 *   - each iteration: a branch on a late value (a chain of loads) with a pseudo random direction; the then-block derefs a pointer: valid (P) when the
 *     branch falls through, NULL-ish (0x20) when it is taken, so the mispredicted fall-through runs it with 0x20 and faults; t3 holds the address of a
 *     fresh line X_i before the branch (the value the old register still has), the consumer `ld t4, 0(t3)` would read that line;
 *   - the correct path then loads X_i: the cycles depend on whether the wrong path fetched it.
 * The gate is the cycle equality of the model and the RTL plus the per-commit function-model check.  Same source for rv32 and rv64 (-DRV64).
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

#ifdef RV64
    .macro LDX a, b
    ld   \a, \b
    .endm
#define SATP_VAL 0x8000000000080003
#else
    .macro LDX a, b
    lw   \a, \b
    .endm
#define SATP_VAL 0x80080003
#endif

_start:
    li   s0, 0x80002000       /* P: holds its own address */
    li   s9, 0x80008000       /* X_i: a fresh line per iteration */
    li   s1, 1
    li   s2, 0x7a5b9d3
    li   s5, 0
    li   t0, SATP_VAL
    csrw satp, t0
    sfence.vma
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11) | (1 << 17)   /* MPP = S, MPRV = 1: the loads and stores translate */
    csrs mstatus, t0
    li   s3, 96
loop:
    mul  s4, s1, s2           /* pseudo random bit */
    addi s4, s4, 1
    srli a3, s4, 7
    andi a3, a3, 1            /* 1: the branch is taken (the then-block is skipped) */
    mv   t3, s9               /* the old value of the consumer's base register */
    neg  a4, a3               /* t0 = a3 ? 0x20 : P */
    li   a5, 0x20
    and  a5, a5, a4
    not  a4, a4
    and  a4, a4, s0
    or   t0, a5, a4
    mv   t1, s0               /* late value: a chain of dependent loads (= P) */
    LDX  t1, 0(t1)
    LDX  t1, 0(t1)
    LDX  t1, 0(t1)
    xor  t5, t1, s0
    or   t5, t5, a3
    bnez t5, skip
    LDX  t3, 0(t0)            /* then-block: faults on the wrong path (t0 = 0x20) */
    LDX  t4, 0(t3)            /* its consumer */
    add  s5, s5, t4
skip:
    LDX  t6, 0(s9)            /* the correct path reads the line X_i */
    add  s5, s5, t6
    mv   s1, s4
    addi s9, s9, 64
    addi s3, s3, -1
    bnez s3, loop
    li   a0, 0
    ebreak

    .org 0x2000
#ifdef RV64
    .dword 0x80002000
    .org 0x3010
    .dword 0x200000cf         /* root[2]: the leaf for 0x80000000.. (V R W X A D) */
#else
    .word 0x80002000
    .org 0x3800
    .word 0x200000cf          /* root[0x200]: the megapage for 0x80000000.. */
#endif
