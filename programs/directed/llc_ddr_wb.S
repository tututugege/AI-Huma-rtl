/* Directed test: LLC dirty eviction -> AXI DDR writeback (AW/W/B) -> DDR readback verify.
 * LLC geometry: 4096 sets x 16 ways x 64B line = 4 MiB -> way stride = 0x40000 (256 KiB).
 * DCache geometry: 256 sets x 4 ways x 64B line = 16 KiB (divides 0x40000).
 * Writing 24 lines at stride 0x40000 into the same LLC set forces >4 DCache dirty evictions into LLC
 * and >16 LLC dirty evictions out to DDR over AXI AW/W/B, then reads all 24 lines back and verifies.
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    li   s0, 0x80100000         /* base address (1 MiB above text) */
    li   s1, 0x00040000         /* 256 KiB stride = same LLC set & same DCache set */
    li   s2, 40                 /* 40 ways >> 16 LLC ways + 4 DCache ways -> guarantees heavy dirty writebacks to DDR */
    li   s3, 0x1122334455667788 /* base magic */

    /* Phase 1: Write 24 lines in set 0 and set 1 (offset 0 and +64) */
    li   t0, 0
    mv   t1, s0
write_loop:
    add  t2, s3, t0
    slli t3, t0, 32
    xor  t2, t2, t3
    sd   t2, 0(t1)
    not  t4, t2
    sd   t4, 8(t1)
    sd   t2, 64(t1)             /* set 1 */
    sd   t4, 72(t1)
    add  t1, t1, s1
    addi t0, t0, 1
    bltu t0, s2, write_loop

    /* Phase 2: Read all 24 lines back from DDR/LLC and verify exact data */
    li   t0, 0
    mv   t1, s0
read_loop:
    add  t2, s3, t0
    slli t3, t0, 32
    xor  t2, t2, t3
    not  t4, t2

    ld   t5, 0(t1)
    bne  t5, t2, fail
    ld   t6, 8(t1)
    bne  t6, t4, fail
    ld   t5, 64(t1)
    bne  t5, t2, fail
    ld   t6, 72(t1)
    bne  t6, t4, fail

    add  t1, t1, s1
    addi t0, t0, 1
    bltu t0, s2, read_loop

    /* Phase 3: Re-dirty first 20 lines to trigger second wave of writebacks */
    li   t0, 0
    mv   t1, s0
    li   s4, 20
write2_loop:
    add  t2, s3, t0
    addi t2, t2, 0x55
    sd   t2, 0(t1)
    add  t1, t1, s1
    addi t0, t0, 1
    bltu t0, s4, write2_loop

    /* Verify first 20 lines */
    li   t0, 0
    mv   t1, s0
read2_loop:
    add  t2, s3, t0
    addi t2, t2, 0x55
    ld   t5, 0(t1)
    bne  t5, t2, fail
    add  t1, t1, s1
    addi t0, t0, 1
    bltu t0, s4, read2_loop

    li   a0, 0
    ebreak

fail:
    j    fail
