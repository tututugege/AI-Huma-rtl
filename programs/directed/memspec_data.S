/* Directed test of the VALUE path of the memory-dependence speculation (EXP-020, LSU_MS_DATA): a load passes an older store
 * whose address is still unknown (the store address comes from a chain of dependent loads), reads the STALE value, and
 * everything that consumes that value executes on stale data until the commit-time flush of the violating load:
 *   - conditional branches on the stale value (the branch resolves the wrong way: a mispredict redirect that the oracle
 *     driven model only knows through the stale-value evaluator; both flips are produced: to mispredict and to correct),
 *   - JALR on a stale pointer (wrong target),
 *   - ALU chains (shift / add / xor / mul / divu / remu / sltu, rv64: the W forms) ending in a branch,
 *   - a store whose DATA is stale (read back by a load: store-to-load forwarding of the stale data),
 *   - partial overlaps (byte / half / word / dword stores under wider loads, sign / zero extending loads).
 * The gate is the cycle equality of the model and the RTL plus the per-commit function-model check of the SoC testbench.
 * Same source for rv32 (-march=rv32ima) and rv64 (-march=rv64ima -DRV64).  No stale ADDRESS is used (the model does not
 * evaluate it: LSU_MS_DATA bit 2).
 *   P = 0x80002000  holds its own address (the pointer chain: every load of the chain returns P)
 *   T = P + 16      store target, written through the late address (the chain result + 16)
 *   U = P + 32      second target (stale store data / no overlap)
 * Register use: s0 P, a2 T, a3 U, s1 last value stored to T, s2 multiplier, s3 pass counter, s5 accumulator, s6 block counter.
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

    /* a fresh value: pseudo random bits, never equal to the previous one */
    .macro NEWVAL
    mul  s4, s1, s2
    addi s4, s4, 1
    .endm

    /* branch on the stale value, same direction every time (the predictor trains, the stale evaluation flips to mispredict) */
    .macro BLK_BRSAME n
    CHAIN \n
    NEWVAL
    STX  s4, 16(t1)
    LDX  t3, 0(a2)
    xor  t4, t3, s4          /* true 0, stale s1^s4 */
    bnez t4, 1f
    addi s5, s5, 7
1:  add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* branch on one bit of the stale value: pseudo random direction (flips to mispredict and to correct) */
    .macro BLK_BRBIT n, bit
    CHAIN \n
    NEWVAL
    STX  s4, 16(t1)
    LDX  t3, 0(a2)
    andi t4, t3, (1 << \bit)
    beqz t4, 1f
    addi s5, s5, 5
1:  add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* signed / unsigned compares of the stale value against the true one */
    .macro BLK_BRCMP n
    CHAIN \n
    NEWVAL
    STX  s4, 16(t1)
    LDX  t3, 0(a2)
    blt  t3, s4, 1f
    addi s5, s5, 3
1:  bgeu t3, s4, 2f
    addi s5, s5, 9
2:  add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* JALR on a stale pointer: the target alternates between two code addresses */
    .macro BLK_JALR n
    la   t4, tgt_a
    la   t5, tgt_b
    andi s7, s6, 1
    mv   t6, t4                /* new pointer (late store) */
    mv   t0, t5                /* old pointer (early store: the stale value is a valid target) */
    beqz s7, 1f
    mv   t6, t5
    mv   t0, t4
1:  STX  t0, 0(a2)
    CHAIN \n
    STX  t6, 16(t1)
    LDX  t3, 0(a2)
    la   s8, 2f
    jr   t3
2:  addi s6, s6, 1
    .endm

    /* ALU chain on the stale value ending in a branch */
    .macro BLK_ALU n
    CHAIN \n
    NEWVAL
    STX  s4, 16(t1)
    LDX  t3, 0(a2)
    slli t4, t3, 3
    add  t4, t4, t3
    xor  t4, t4, s2
    mul  t5, t4, t3
    srli t5, t5, 5
    ori  t6, t4, 1
    remu t5, t5, t6
    sltu t6, t5, t4
    add  t4, t4, t6
    divu t5, t4, s2
    sub  t4, t4, t5
    srai t5, t4, 3
    xor  t4, t4, t5
    andi t6, t4, 64
    bnez t6, 1f
    addi s5, s5, 11
1:  add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

#ifdef RV64
    /* the W forms and the extending loads of rv64 */
    .macro BLK_ALUW n
    CHAIN \n
    NEWVAL
    STX  s4, 16(t1)
    LDX  t3, 0(a2)
    addw t4, t3, s2
    sllw t5, t3, s2
    srlw t6, t4, t5
    sraw t4, t4, t6
    mulw t5, t4, t3
    ori  t6, t5, 1
    divuw t5, t4, t6
    remw t6, t4, t6
    addiw t4, t4, 77
    slliw t4, t4, 3
    sraiw t4, t4, 2
    sub  t4, t4, t6
    mulh t5, t3, t4
    mulhu t6, t3, t4
    xor  t4, t5, t6
    andi t6, t4, 32
    bnez t6, 1f
    addi s5, s5, 13
1:  add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* a dword store (late) under narrower loads: sign / zero extension, partial overlap with the old dword */
    .macro BLK_EXT n
    CHAIN \n
    NEWVAL
    sd   s4, 16(t1)
    lw   t3, 0(a2)
    lwu  t4, 4(a2)
    lb   t5, 3(a2)
    lhu  t6, 6(a2)
    add  s5, s5, t3
    xor  s5, s5, t4
    add  s5, s5, t5
    add  s5, s5, t6
    bltz t3, 1f
    addi s5, s5, 17
1:  addi s6, s6, 1
    mv   s1, s4
    .endm

    /* a word store (late) into the upper half, a dword load of the whole unit */
    .macro BLK_HALF n
    CHAIN \n
    NEWVAL
    sw   s4, 20(t1)
    ld   t3, 0(a2)
    srli t4, t3, 32
    sub  t4, t4, s4
    bnez t4, 1f
    addi s5, s5, 19
1:  add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm
#endif

    /* the stale value becomes the DATA of a store, read back through store-to-load forwarding */
    .macro BLK_STDATA n
    CHAIN \n
    NEWVAL
    STX  s4, 16(t1)
    LDX  t3, 0(a2)
    STX  t3, 0(a3)
    LDX  t4, 0(a3)
    xor  t5, t4, s4
    andi t6, t5, 16
    bnez t6, 1f
    addi s5, s5, 23
1:  add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* partial overlaps: a byte store (late) merges into the word, the load sees old bytes and the new one */
    .macro BLK_PART n
    CHAIN \n
    NEWVAL
    andi t4, s4, 0xff
    sb   t4, 17(t1)
    lw   t3, 0(a2)
    srli t5, t3, 8
    andi t5, t5, 0xff
    xor  t5, t5, t4
    bnez t5, 1f
    addi s5, s5, 29
1:  add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* a halfword store (late) under a byte load */
    .macro BLK_BYTE n
    CHAIN \n
    NEWVAL
    sh   s4, 18(t1)
    lbu  t3, 2(a2)
    lb   t4, 3(a2)
    xor  t5, t3, t4
    andi t5, t5, 8
    bnez t5, 1f
    addi s5, s5, 31
1:  add  s5, s5, t3
    add  s5, s5, t4
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* speculation without a violation: the store goes to U, the load reads T */
    .macro BLK_NONE n
    CHAIN \n
    NEWVAL
    STX  s4, 32(t1)
    LDX  t3, 0(a2)
    xor  t4, t3, s1
    bnez t4, 1f
    addi s5, s5, 37
1:  add  s5, s5, t3
    addi s6, s6, 1
    .endm

_start:
    li   s0, 0x80002000       /* P */
    addi a2, s0, 16           /* T */
    addi a3, s0, 32           /* U */
    li   s1, 1                /* last value stored to T */
    li   s2, 0x7a5b9d3        /* odd multiplier */
    li   s5, 0
    li   s6, 0
    li   s3, 3                /* passes */
pass:
    BLK_BRSAME 1
    BLK_BRBIT 2, 0
    BLK_BRCMP 3
    BLK_JALR 2
    BLK_ALU 1
    BLK_BRBIT 4, 1
    BLK_STDATA 2
    BLK_BRSAME 3
    BLK_PART 3
    BLK_JALR 4
    BLK_BRBIT 1, 2
    BLK_ALU 3
    BLK_BYTE 2
    BLK_NONE 2
    BLK_BRCMP 1
#ifdef RV64
    BLK_ALUW 2
    BLK_EXT 3
    BLK_HALF 2
    BLK_ALUW 1
    BLK_EXT 1
    BLK_HALF 4
#endif
    BLK_BRBIT 6, 3
    BLK_STDATA 1
    BLK_JALR 1
    BLK_BRSAME 5
    BLK_ALU 2
    BLK_PART 1
    BLK_BRBIT 3, 4
    BLK_BRCMP 2
    BLK_STDATA 3
    BLK_BYTE 4
    BLK_BRBIT 2, 5
    BLK_JALR 3
    BLK_BRSAME 2
    BLK_NONE 1
    BLK_ALU 4
    addi s3, s3, -1
    bnez s3, pass
    li   a0, 0
    ebreak

tgt_a:
    addi s5, s5, 41
    jr   s8
tgt_b:
    addi s5, s5, 43
    jr   s8

    .org 0x2000
#ifdef RV64
    .dword 0x80002000
#else
    .word 0x80002000
#endif
