/* Directed test of the STALE ADDRESS path of the memory-dependence speculation (LSU_MS_DATA bit 2): a load that passes an older store whose
 * address is still unknown reads a STALE pointer; the instruction that uses that pointer as its BASE register then runs at the stale address
 * until the commit-time flush of the violating load:
 *   - a store through the stale pointer writes to the old region instead of the new one, so a load at the true pointer reads the old memory
 *     (the branch on that value flips: the model knows it only if it follows the stale store address),
 *   - a load through the stale pointer reads the old region (a value that differs from the true one) and feeds a branch / an ALU chain.
 * The gate is the cycle equality of the model and the RTL plus the per-commit function-model check of the SoC testbench.  With the model
 * default LSU_MS_DATA=1 (no stale addresses) the cycles of this program differ from the RTL: the test fails on a model without the feature.
 * Same source for rv32 (-march=rv32ima) and rv64 (-march=rv64ima -DRV64).
 *   P = 0x80002000  holds its own address (the pointer chain: every load of the chain returns P)
 *   T = P + 16      the pointer slot, written through the late address (chain result + 16)
 *   R0 = P + 64, R1 = P + 128   the two regions the pointer alternates between
 * Register use: s0 P, a2 T, s9 R0, s10 R1, s1 last value stored, s2 multiplier, s5 accumulator, s6 block counter, s3 pass counter.
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

#ifdef RV64
    .macro LDX a, b
    ld   \a, \b
    .endm
    .macro STX a, b
    sd   \a, \b
    .endm
#else
    .macro LDX a, b
    lw   \a, \b
    .endm
    .macro STX a, b
    sw   \a, \b
    .endm
#endif

    .macro CHAIN n
    mv   t1, s0
    .rept \n
    LDX  t1, 0(t1)
    .endr
    .endm

    .macro NEWVAL
    mul  s4, s1, s2
    addi s4, s4, 1
    .endm

    /* select the new pointer t6 and the old one t0 by the parity of the block counter, put the old one into the slot (early, known address) */
    .macro SETPTR
    andi s7, s6, 1
    mv   t6, s9
    mv   t0, s10
    beqz s7, 1f
    mv   t6, s10
    mv   t0, s9
1:  STX  t0, 0(a2)
    .endm

    /* a store through the stale pointer, a load at the true pointer, branch on the difference (true: equal, stale: differs) */
    .macro BLK_STSTALE n, off
    SETPTR
    CHAIN \n
    STX  t6, 16(t1)           /* new pointer, late address */
    LDX  t3, 0(a2)            /* stale: the old pointer */
    NEWVAL
    STX  s4, \off(t3)         /* store through the (possibly stale) base */
    LDX  t4, \off(t6)         /* the true address */
    xor  t5, t4, s4
    bnez t5, 1f
    addi s5, s5, 3
1:  add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* a load through the stale pointer: it reads the old region (holds the previous value), the true region holds the value stored before */
    .macro BLK_LDSTALE n, off
    SETPTR
    NEWVAL
    STX  s4, \off(t6)         /* the true region gets the new value (early, known address) */
    CHAIN \n
    STX  t6, 16(t1)
    LDX  t3, 0(a2)            /* stale pointer */
    LDX  t4, \off(t3)         /* through the stale base: the old region */
    xor  t5, t4, s4
    andi t5, t5, 0x40
    bnez t5, 1f
    addi s5, s5, 5
1:  add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* the loaded value is used by an ALU chain that ends in a branch */
    .macro BLK_STALU n, off
    SETPTR
    CHAIN \n
    STX  t6, 16(t1)
    LDX  t3, 0(a2)
    NEWVAL
    STX  s4, \off(t3)
    LDX  t4, \off(t6)
    slli t5, t4, 3
    xor  t5, t5, s4
    add  t5, t5, t4
    srli t5, t5, 2
    andi t5, t5, 16
    bnez t5, 1f
    addi s5, s5, 11
1:  add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

_start:
    li   s0, 0x80002000       /* P */
    addi a2, s0, 16           /* T */
    addi s9, s0, 64           /* R0 */
    addi s10, s0, 128         /* R1 */
    li   s1, 1
    li   s2, 0x7a5b9d3
    li   s5, 0
    li   s6, 0
    li   s3, 3
pass:
    BLK_STSTALE 1, 0
    BLK_STSTALE 2, 8
    BLK_LDSTALE 3, 0
    BLK_STALU 1, 0
    BLK_STSTALE 3, 0
    BLK_LDSTALE 1, 8
    BLK_STALU 2, 8
    BLK_STSTALE 4, 8
    BLK_LDSTALE 2, 0
    BLK_STALU 3, 0
    BLK_STSTALE 1, 8
    BLK_LDSTALE 4, 0
    addi s3, s3, -1
    bnez s3, pass
    li   a0, 0
    ebreak

    .org 0x2000
#ifdef RV64
    .dword 0x80002000
#else
    .word 0x80002000
#endif
