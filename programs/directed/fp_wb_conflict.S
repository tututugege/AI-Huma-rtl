/* Directed regression test: FP writeback port conflict (isu_fp_gate cross-class same-latency collision).
 * Specifically fires 2x I2F (fmv.w.x / fmv.d.x, class 10, lat=2) + FMISC (fsgnj.s / fsgnj.d, class 9, lat=2)
 * in the same issue cycle so isu_fp_gate must throttle to FP_WB_PORTS=2 and never drop a writeback.
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    /* Enable mstatus.FS = Initial (0x2000) */
    li   t0, 0x2000
    csrs mstatus, t0

    li   a1, 0x3f800000         /* +1.0f */
    li   a2, 0xbf800000         /* -1.0f */
    li   a3, 0x40000000         /* +2.0f */
    li   a4, 0x12345678
    li   a5, 0x3ff0000000000000 /* +1.0d */
    li   a6, 0xbff0000000000000 /* -1.0d */

    fmv.w.x f10, a1
    fmv.w.x f11, a2
    fmv.d.x f12, a5
    fmv.d.x f13, a6

    li   s0, 0
    li   s1, 32
loop:
    /* Independent burst: 2x I2F + 2x FMISC + FMA in same dispatch/issue window */
    fmv.w.x  f1, a4
    fmv.w.x  f2, a3
    fsgnj.s  f3, f10, f11       /* -1.0f (0xbf800000) */
    fsgnjn.s f4, f10, f11       /* +1.0f (0x3f800000) */
    fmadd.s  f5, f10, f11, f10  /* 1.0 * -1.0 + 1.0 = +0.0f */

    /* Same for double precision */
    fmv.d.x  f6, a5
    fmv.d.x  f7, a6
    fsgnj.d  f8, f12, f13       /* -1.0d */
    fsgnjx.d f9, f12, f13       /* -1.0d */

    /* Verify every written FP register (catches dropped FP writebacks immediately) */
    fmv.x.w  t1, f1
    bne      t1, a4, fail
    fmv.x.w  t2, f2
    bne      t2, a3, fail
    fmv.x.w  t3, f3
    sext.w   t6, a2
    bne      t3, t6, fail
    fmv.x.w  t4, f4
    bne      t4, a1, fail
    fmv.x.w  t5, f5
    bnez     t5, fail
    fmv.x.d  t1, f6
    bne      t1, a5, fail
    fmv.x.d  t2, f7
    bne      t2, a6, fail
    fmv.x.d  t3, f8
    bne      t3, a6, fail
    fmv.x.d  t4, f9
    bne      t4, a6, fail

    addi a4, a4, 1
    addi s0, s0, 1
    bltu s0, s1, loop

    li   a0, 0
    ebreak

fail:
    j    fail
