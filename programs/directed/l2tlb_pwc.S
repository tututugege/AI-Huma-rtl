/* Directed test of unified L2 TLB (4KB STLB + 3-bit tree-PLRU), Superpage CAM (2MB/1GB), Sv39 PWC (L2/L1),
 * and sfence.vma invalidation.
 *   1. Builds Sv39 3-level page tables in M-mode at 0x80010000:
 *      - root[2]: 1GB leaf 0x80000000 -> 0x80000000
 *      - root[0]: ptr -> L1 (0x80011000)
 *      - L1[0]: ptr -> L0_0 (0x80012000), mapping 80 x 4KB pages VA 0x00000000..0x0004f000 -> PA 0x80100000..0x8014f000
 *      - L1[1]: 2MB leaf VA 0x00200000 -> PA 0x80200000
 *      - L1[2..6]: ptrs -> L0_2..L0_6 (0x80013000..0x80017000), each mapping vpn0 == vpn1 (idx = vpn0^vpn1 = 0)
 *        so all 5 pages map to STLB set 0 -> exercises 4-way tree-PLRU eviction.
 *   2. Enables MPRV=1, MPP=S, Sv39.
 *      - Walks 80 4KB pages (populates PWC L2/L1 + STLB, overflows 64-entry L1 DTLB).
 *      - Re-reads first 16 pages (STLB hits + PLRU touch).
 *      - Reads 2MB superpage, overflows DTLB, re-reads 2MB superpage (SP CAM hit).
 *      - Reads 5 same-set pages in set 0 (PLRU eviction), then re-reads page 2 (evicted -> PWC L1 hit + STLB refill).
 *      - Rewrites L0_0[0] to map VA 0x00000000 -> PA 0x8014f000 (magic 0xdeadbeef), executes sfence.vma,
 *        and reads VA 0x00000000: must observe 0xdeadbeef (proves STLB/SP/PWC flushed by sfence.vma).
 */
    .option norvc
    .option norelax
    .section .text.start,"ax",@progbits
    .globl _start

_start:
    /* ---- 1. Build Sv39 page tables in M-mode (MPRV=0) ---- */
    /* Zero 0x80010000 .. 0x80018000 (8 x 4KB pages) */
    li   t0, 0x80010000
    li   t1, 0x80018000
zero_pt:
    sd   zero, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, zero_pt

    /* root[2] = 1GB leaf for 0x80000000 (PPN=0x80000, flags=0xcf: V R W X A D) */
    li   t0, 0x80010010
    li   t1, (0x80000 << 10) | 0xcf
    sd   t1, 0(t0)

    /* root[0] = pointer to L1 at 0x80011000 (PPN=0x80011, flags=0x01: V) */
    li   t0, 0x80010000
    li   t1, (0x80011 << 10) | 0x01
    sd   t1, 0(t0)

    /* L1[0] = pointer to L0_0 at 0x80012000 */
    li   t0, 0x80011000
    li   t1, (0x80012 << 10) | 0x01
    sd   t1, 0(t0)

    /* L1[1] = 2MB superpage leaf VA 0x00200000 -> PA 0x80200000 (PPN=0x80200, flags=0xcf) */
    li   t0, 0x80011008
    li   t1, (0x80200 << 10) | 0xcf
    sd   t1, 0(t0)

    /* L0_0[0..79]: 80 x 4KB pages VA i*4KB -> PA (0x80100 + i)*4KB; write distinct marker to each page */
    li   s0, 0                  /* i = 0 */
    li   s1, 80
    li   t0, 0x80012000         /* &L0_0[0] */
    li   t1, 0x80100            /* PPN */
    li   t2, 0x80100000         /* PA */
fill_l0_0:
    slli t3, t1, 10
    ori  t3, t3, 0xcf           /* V R W X A D */
    sd   t3, 0(t0)
    addi t4, s0, 100
    sd   t4, 0(t2)              /* marker = 100 + i */
    addi t0, t0, 8
    addi t1, t1, 1
    li   t5, 0x1000
    add  t2, t2, t5
    addi s0, s0, 1
    bltu s0, s1, fill_l0_0

    /* Write magic 0xdeadbeef to PA 0x8014f000 (page 79) for sfence.vma remap check */
    li   t0, 0x8014f000
    li   t1, 0xdeadbeef
    sd   t1, 0(t0)

    /* Write marker 0x2222 to 2MB superpage PA 0x80200000 and 0x80201000 */
    li   t0, 0x80200000
    li   t1, 0x2222
    sd   t1, 0(t0)
    li   t0, 0x80201000
    sd   t1, 0(t0)

    /* L1[2..6] -> L0_2..L0_6 (0x80013000..0x80017000), each mapping vpn0 = vpn1 (k in 2..6) -> STLB set 0 */
    li   s0, 2                  /* k = 2..6 */
    li   s1, 7
fill_set0:
    /* L1[k] = ptr to 0x80011000 + k*0x1000 (k=2 -> 0x80013000) */
    li   t0, 0x80011000
    slli t1, s0, 3
    add  t0, t0, t1             /* &L1[k] */
    li   t2, 0x80011
    add  t2, t2, s0             /* PPN of L0_k */
    slli t3, t2, 10
    ori  t3, t3, 0x01
    sd   t3, 0(t0)

    /* L0_k[k] = 4KB leaf -> PA (0x80160 + k)*4KB */
    slli t4, t2, 12             /* base of L0_k */
    add  t4, t4, t1             /* &L0_k[k] */
    li   t5, 0x80160
    add  t5, t5, s0
    slli t6, t5, 10
    ori  t6, t6, 0xcf
    sd   t6, 0(t4)
    slli t5, t5, 12
    sd   s0, 0(t5)              /* marker = k */

    addi s0, s0, 1
    bltu s0, s1, fill_set0

    /* ---- 2. Enable Sv39 (MPRV=1, MPP=S) ---- */
    li   t0, (8 << 60) | 0x80010
    csrw satp, t0
    sfence.vma
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11) | (1 << 17)
    csrs mstatus, t0

    /* ---- 3. Walk 80 4KB pages (populates PWC L2/L1 + STLB, overflows 64-entry L1 DTLB) ---- */
    li   s5, 0                  /* checksum */
    li   s0, 0
    li   s1, 80
    li   t0, 0
    li   t5, 0x1000
walk_80:
    ld   t1, 0(t0)
    add  s5, s5, t1
    add  t0, t0, t5
    addi s0, s0, 1
    bltu s0, s1, walk_80

    /* ---- 4. Re-read first 16 pages (L1 DTLB miss -> STLB 2-cycle hit + PLRU touch) ---- */
    li   s0, 0
    li   s1, 16
    li   t0, 0
hit_16:
    ld   t1, 0(t0)
    add  s5, s5, t1
    add  t0, t0, t5
    addi s0, s0, 1
    bltu s0, s1, hit_16

    /* ---- 5. 2MB superpage fill + DTLB overflow + SP CAM hit ---- */
    li   t0, 0x00200000
    ld   t1, 0(t0)
    add  s5, s5, t1
    /* Access 68 pages to evict 2MB entry from 64-entry L1 DTLB */
    li   s0, 0
    li   s1, 68
    li   t0, 0
evict_dtlb:
    ld   t1, 0(t0)
    add  s5, s5, t1
    add  t0, t0, t5
    addi s0, s0, 1
    bltu s0, s1, evict_dtlb
    /* Re-read 2MB superpage at offset +0x1000 (L1 DTLB miss -> SP CAM hit!) */
    li   t0, 0x00201000
    ld   t1, 0(t0)
    add  s5, s5, t1

    /* ---- 6. 5 same-set pages in STLB set 0 (vpn1=k, vpn0=k for k=2..6) -> 4-way PLRU eviction ---- */
    li   s0, 2
    li   s1, 7
plru_fill:
    slli t0, s0, 21             /* vpn1 = k */
    slli t1, s0, 12             /* vpn0 = k */
    or   t0, t0, t1
    ld   t2, 0(t0)
    add  s5, s5, t2
    addi s0, s0, 1
    bltu s0, s1, plru_fill
    /* Re-read k=2 (evicted from 4-way set 0 -> PWC L1 hit + STLB refill) */
    li   t0, (2 << 21) | (2 << 12)
    ld   t2, 0(t0)
    add  s5, s5, t2

    /* ---- 7. Remap VA 0x00000000 -> PA 0x8014f000 (magic 0xdeadbeef), sfence.vma, verify ---- */
    /* Write L0_0[0] via 1GB identity mapping at 0x80012000 */
    li   t0, 0x80012000
    li   t1, (0x8014f << 10) | 0xcf
    sd   t1, 0(t0)
    sfence.vma
    li   t0, 0
    ld   t2, 0(t0)              /* MUST read 0xdeadbeef, NOT old 100 */
    li   t3, 0xdeadbeef
    xor  a0, t2, t3             /* a0 = 0 on pass */
    ebreak
