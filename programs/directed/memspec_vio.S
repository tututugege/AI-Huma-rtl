/* Directed test of the memory-dependence speculation (LSU_MEMSPEC=1): a load passes an older store whose address is
 * still unknown (it comes from a chain of dependent loads), reads the stale value, and has to be replayed and flushed
 * when the store address arrives and overlaps.  The check is the per-commit comparison of the SoC testbench with the
 * function model (every load result and every accumulation of it).  There is deliberately no branch on a loaded value:
 * the RTL executes with the real (stale) data while the trace-driven model uses oracle values, so a branch on stale
 * data would mispredict in the RTL only and break the cycle equality of the two.
 *   P  = 0x80001000   word that holds its own address (the pointer chain: each load of the chain returns P again)
 *   T  = P + 16       the store target, written through the late address (the chain result + 16)
 *   U  = P + 32       a store target that never overlaps the loads below (a speculation without a violation)
 * Blocks differ in chain length (the time the store address arrives relative to the load), in store / load sizes (full
 * and partial overlap) and in the PC (the wait table is indexed by the load PC; three passes: the second and third see
 * the table trained by the first).  s5 accumulates every loaded value, s6 counts the blocks.
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

    .macro CHAIN n
    mv   t1, s0
    .rept \n
    lw   t1, 0(t1)
    .endr
    .endm

    /* full overlap: sw (late) then lw of the same word; the load must see the stored value */
    .macro BLK_FULL n
    CHAIN \n
    addi s4, s1, 1
    sw   s4, 16(t1)
    lw   t3, 0(a2)
    mv   s1, s4
    add  s5, s5, t3
    addi s6, s6, 1
    .endm

    /* partial overlap: sb (late) into byte 1 of T, then lw of the word: stored byte merged into the old word */
    .macro BLK_PART n
    CHAIN \n
    addi s4, s1, 1
    andi t4, s4, 0xff
    sb   t4, 17(t1)
    lw   t3, 0(a2)
    srli t5, t3, 8
    andi t5, t5, 0xff
    add  s5, s5, t5
    add  s5, s5, t4
    add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* byte load under a halfword store with a late address */
    .macro BLK_BYTE n
    CHAIN \n
    addi s4, s1, 1
    sh   s4, 18(t1)
    lbu  t3, 2(a2)
    slli t4, s4, 16
    srli t4, t4, 16
    andi t5, t4, 0xff
    add  s5, s5, t5
    add  s5, s5, t3
    addi s6, s6, 1
    mv   s1, s4
    .endm

    /* no overlap: the store goes to U, the load reads T: speculation without a violation */
    .macro BLK_NONE n
    CHAIN \n
    addi s4, s1, 3
    sw   s4, 32(t1)
    lw   t3, 0(a2)
    add  s5, s5, t3
    addi s6, s6, 1
    .endm

_start:
    lui  s0, 0x80001          /* P */
    addi a2, s0, 16           /* T */
    li   s1, 0                /* last value stored to T */
    li   s5, 0
    li   s6, 0
    li   s3, 3                /* passes */
pass:
    BLK_FULL 1
    BLK_FULL 2
    BLK_FULL 3
    BLK_FULL 4
    BLK_FULL 6
    BLK_NONE 2
    BLK_FULL 1
    BLK_FULL 5
    BLK_PART 3
    BLK_FULL 3
    BLK_BYTE 2
    BLK_FULL 7
    BLK_FULL 4
    BLK_NONE 3
    BLK_FULL 2
    BLK_FULL 1
    BLK_FULL 6
    BLK_FULL 3
    BLK_PART 1
    BLK_FULL 2
    BLK_BYTE 4
    BLK_FULL 1
    BLK_PART 5
    BLK_FULL 2
    BLK_BYTE 1
    BLK_NONE 1
    BLK_FULL 5
    BLK_FULL 2
    BLK_FULL 3
    BLK_FULL 1
    BLK_FULL 6
    addi s3, s3, -1
    bnez s3, pass
    /* 3 passes x 30 blocks */
    li   a0, 0
    ebreak
    .org 0x1000
    .word 0x80001000
