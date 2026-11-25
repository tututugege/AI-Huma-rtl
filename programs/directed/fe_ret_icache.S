/* Directed test: Frontend non-zero-offset RET (jalr x0, imm(ra)) + ICache 8-way SRRIP eviction.
 * ICache geometry: 64 sets x 8 ways x 64B line = 32 KiB -> way stride = 0x1000 (4 KiB).
 * Calling 12 stubs spaced by 4 KiB all hit ICache set 0, exceeding 8 ways and exercising all SRRIP rrpv levels.
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    /* ---- Part 1: Non-zero-offset jalr x0, 8(ra) (must jump to ra+8, not pop normal RET to ra) ---- */
    li   s0, 0
    li   s1, 8
ret_loop:
    jal  ra, callee_offset
    j    fail                   /* ra+0: must be skipped! */
    j    fail                   /* ra+4: must be skipped! */
    addi s0, s0, 1              /* ra+8: actual return target */
    bltu s0, s1, ret_loop

    /* ---- Part 2: ICache 8-way SRRIP conflict across 12 stubs at 4 KiB stride ---- */
    li   s2, 0                  /* accumulator */
    li   s3, 0                  /* outer rounds */
    li   s4, 4
ic_round:
    jal  ra, stub_0
    jal  ra, stub_1
    jal  ra, stub_2
    jal  ra, stub_3
    jal  ra, stub_4
    jal  ra, stub_5
    jal  ra, stub_6
    jal  ra, stub_7
    jal  ra, stub_8
    jal  ra, stub_9
    jal  ra, stub_10
    jal  ra, stub_11
    addi s3, s3, 1
    bltu s3, s4, ic_round

    /* Expected accumulator: 4 rounds * (1+2+...+12) = 4 * 78 = 312 */
    li   t0, 312
    bne  s2, t0, fail

    li   a0, 0
    ebreak

callee_offset:
    jalr x0, 8(ra)

fail:
    j    fail

    .macro IC_STUB idx, val
    .balign 0x1000
stub_\idx:
    addi s2, s2, \val
    ret
    .endm

    IC_STUB 0, 1
    IC_STUB 1, 2
    IC_STUB 2, 3
    IC_STUB 3, 4
    IC_STUB 4, 5
    IC_STUB 5, 6
    IC_STUB 6, 7
    IC_STUB 7, 8
    IC_STUB 8, 9
    IC_STUB 9, 10
    IC_STUB 10, 11
    IC_STUB 11, 12
