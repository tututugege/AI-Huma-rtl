/* Directed test: LSU write-buffer pending (L2_WBP), DCache store-resp pressure, and sub-word/cross-word STLF.
 * Covers:
 *   - lp_ldq_ent.sv L2_WBP path (loads hitting committed/pending stores in STQ/WBP)
 *   - partial & cross-word store-to-load forwarding (sb/sh/sw/sd -> lb/lbu/lh/lhu/lw/lwu/ld)
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    li   s0, 0x80020000         /* scratch buffer */

    /* ---- Part 1: Rapid store burst + immediate load-back to trigger STQ/WBP -> L2_WBP ---- */
    li   s1, 0
    li   s2, 16
burst_loop:
    li   t0, 0x0102030405060708
    add  t0, t0, s1
    /* Fill multiple cache lines in DCache/WBP to create write-buffer backpressure */
    sd   t0, 0(s0)
    sd   t0, 64(s0)
    sd   t0, 128(s0)
    sd   t0, 192(s0)
    sd   t0, 256(s0)
    sd   t0, 320(s0)
    sd   t0, 384(s0)
    sd   t0, 448(s0)
    sd   t0, 512(s0)
    sd   t0, 576(s0)
    sd   t0, 640(s0)
    sd   t0, 704(s0)
    /* Immediately read back same addresses while stores are draining through WBP/DCache */
    ld   t1, 0(s0)
    bne  t1, t0, fail
    ld   t2, 64(s0)
    bne  t2, t0, fail
    ld   t3, 128(s0)
    bne  t3, t0, fail
    ld   t4, 192(s0)
    bne  t4, t0, fail
    ld   t5, 256(s0)
    bne  t5, t0, fail
    ld   t6, 512(s0)
    bne  t6, t0, fail
    li   t6, 0x1000
    add  s0, s0, t6             /* next 4KB page so DCache sets conflict/evict */
    addi s1, s1, 1
    bltu s1, s2, burst_loop

    /* ---- Part 2: Sub-word / partial overlap / adjacent-word STLF matrix ---- */
    li   s0, 0x80020000
    li   s1, 0
    li   s2, 8
ovl_loop:
    li   t0, 0x1122334455667788
    add  t0, t0, s1
    sd   t0, 0(s0)
    not  t1, t0
    sd   t1, 8(s0)              /* adjacent 64-bit word */

    /* Overwrite byte 1, halfword at +2, word at +4 */
    li   t2, 0xaa
    sb   t2, 1(s0)
    li   t3, 0xbbcc
    sh   t3, 2(s0)
    li   t4, 0xddeeff00
    sw   t4, 4(s0)

    /* Immediate loads at various widths & offsets */
    lbu  t5, 1(s0)
    bne  t5, t2, fail
    lhu  t5, 2(s0)
    bne  t5, t3, fail
    lwu  t5, 4(s0)
    li   t6, 0xddeeff00
    bne  t5, t6, fail
    /* Full 64-bit load merging 4 stores (sd + sb + sh + sw) */
    ld   t5, 0(s0)
    andi t6, t0, 0xff
    li   a1, 0xddeeff00bbccaa00
    or   a1, a1, t6
    bne  t5, a1, fail
    /* Adjacent word must remain untouched */
    ld   t5, 8(s0)
    bne  t5, t1, fail

    addi s0, s0, 16
    addi s1, s1, 1
    bltu s1, s2, ovl_loop

    li   a0, 0
    ebreak

fail:
    j    fail
