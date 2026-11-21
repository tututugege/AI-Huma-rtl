/* Directed test for Milestone B front-end (2-taken 1-Ahead A + 2-Ahead B FTB BPU, 4-bank 1R1W ICache, FDIP):
 *   1) Tight 2-taken alternating hops across distinct ICache banks (bank 0 -> bank 1 -> bank 2 -> bank 3) to
 *      exercise 2-Ahead B pairing, Bank B parallel fetch_second, dual-segment predecode_checker, and FTQ next_pc.
 *   2) Same-bank pair (bank 0 -> bank 0 different line, +256B) to exercise ic_pair_ok rejection.
 *   3) Call/return chain inside paired blocks to exercise 4-slot RAS overlay and back-end repair via internal rec_q.
 *   4) Conditional branch mispredict inside paired Block B (changing direction on iteration 12) to verify rec_q[256]
 *      repair with Block B blk_id (seq1).
 *   5) Cold multi-line sequential + hopping code stream (64 cache lines) to exercise S2-confirmed 2-slot real-AXI FDIP.
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    li   s0, 0          /* accumulator */
    li   s1, 20         /* loop count for 2-taken bank-hopping + Block B mispredict */

    /* ---- Phase 1: 2-taken cross-bank hops (bank 0 -> bank 1 -> bank 2 -> bank 3) + Block B branch ---- */
    .p2align 6          /* 64B aligned: bank 0 */
hop0:
    addi s0, s0, 1
    j    hop1

    .p2align 6          /* +64B: bank 1 */
hop1:
    addi s0, s0, 2
    j    hop2

    .p2align 6          /* +128B: bank 2 */
hop2:
    addi s0, s0, 4
    j    hop3

    .p2align 6          /* +192B: bank 3 */
hop3:
    addi s1, s1, -1
    li   t0, 8
    beq  s1, t0, hop_mispred  /* flips taken once mid-loop (Block B mispredict & rec_q repair) */
    bnez s1, hop0
    j    phase2

    .p2align 6
hop_mispred:
    addi s0, s0, 17
    bnez s1, hop0

    /* ---- Phase 2: Same-bank pair (bank 0 -> bank 0, +256B) + call/return RAS pairing ---- */
    .p2align 8          /* 256B aligned: bank 0 */
phase2:
    li   s1, 10
sb_loop:
    addi s0, s0, 3
    j    sb_target
    .p2align 8          /* +256B: also bank 0 (ic_pair_ok == 0) */
sb_target:
    call leaf_fn
    addi s1, s1, -1
    bnez s1, sb_loop
    j    phase3

    .p2align 6
leaf_fn:
    addi s0, s0, 5
    ret

    /* ---- Phase 3: Cold 32-line hopping stream (exercises S2-confirmed real-AXI FDIP + pair miss) ---- */
    .p2align 6
phase3:
    .irp idx, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .p2align 6
    addi s0, s0, \idx + 1
    j    fdip_next_\idx
fdip_next_\idx:
    .endr

    mv   a0, zero
    ebreak
