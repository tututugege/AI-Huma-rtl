#!/usr/bin/env python3
"""Lightweight microarchitecture-aware RV64GC baremetal fuzzer generator.

Generates guaranteed-terminating RV64GC assembly programs targeting OoO CPU corners:
  - alu_fp    : ALU/Zba/Zbb, move-elimination chains, MUL/DIV/W-forms, F/D writeback storms
  - lsu_stlf  : narrow-window multi-width STLF overlaps, WBP/STQ pressure, AMOs, DCache conflicts
  - fe_rvc    : 16b/32b RVC mix, dense forward branches, bounded short loops, JAL/JALR/RAS, fence.i
  - priv_trap : CSR r/w, controlled ecall / illegal-inst traps, sfence.vma, precise flush recovery
  - mixed     : weighted combination of all profiles (default)
"""
import argparse
import random

# Active register pools (avoid x0, sp/gp/tp, s0/s1 sandbox bases, s10/s11 loop/trap guards)
INT_REGS = ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5"]
FP_REGS  = [f"f{i}" for i in range(16)]
# Sandbox bases: s0 = 0x80020000, s1 = 0x80024000 (16 KiB apart -> same DCache set!)
MEM_BASES = ["s0", "s1"]

ALU_RR = ["add", "sub", "xor", "or", "and", "sll", "srl", "sra", "slt", "sltu",
          "addw", "subw", "sllw", "srlw", "sraw"]
ALU_RI = ["addi", "xori", "ori", "andi", "slti", "sltiu", "addiw"]
ZBB_RR = ["sh1add", "sh2add", "sh3add", "min", "max", "minu", "maxu", "rol", "ror", "rolw", "rorw"]
ZBB_R1 = ["clz", "ctz", "cpop", "clzw", "ctzw", "cpopw", "sext.b", "sext.h", "rev8"]
MUL_RR = ["mul", "mulh", "mulhu", "mulhsu", "mulw"]
DIV_RR = ["div", "divu", "rem", "remu", "divw", "divuw", "remw", "remuw"]

FP_S_BIN = ["fadd.s", "fsub.s", "fmul.s", "fmin.s", "fmax.s", "fsgnj.s", "fsgnjn.s", "fsgnjx.s"]
FP_D_BIN = ["fadd.d", "fsub.d", "fmul.d", "fmin.d", "fmax.d", "fsgnj.d", "fsgnjn.d", "fsgnjx.d"]
FP_S_FMA = ["fmadd.s", "fmsub.s", "fnmadd.s", "fnmsub.s"]
FP_D_FMA = ["fmadd.d", "fmsub.d", "fnmadd.d", "fnmsub.d"]
FP_CMP   = ["feq.s", "flt.s", "fle.s", "feq.d", "flt.d", "fle.d"]


def rint(rng): return rng.choice(INT_REGS)
def rfp(rng):  return rng.choice(FP_REGS)


def gen_alu_step(rng):
    k = rng.random()
    rd, rs1, rs2 = rint(rng), rint(rng), rint(rng)
    if k < 0.28:
        return [f"{rng.choice(ALU_RR)} {rd}, {rs1}, {rs2}"]
    elif k < 0.45:
        imm = rng.randint(-1024, 1023)
        return [f"{rng.choice(ALU_RI)} {rd}, {rs1}, {imm}"]
    elif k < 0.60:
        # Move-elimination chain (2-4 hops)
        chain = []
        cur = rs1
        for _ in range(rng.randint(2, 4)):
            nxt = rint(rng)
            chain.append(f"mv {nxt}, {cur}")
            cur = nxt
        return chain
    elif k < 0.72:
        return [f"{rng.choice(ZBB_RR)} {rd}, {rs1}, {rs2}"]
    elif k < 0.80:
        return [f"{rng.choice(ZBB_R1)} {rd}, {rs1}"]
    elif k < 0.90:
        return [f"{rng.choice(MUL_RR)} {rd}, {rs1}, {rs2}"]
    else:
        return [f"{rng.choice(DIV_RR)} {rd}, {rs1}, {rs2}"]


def gen_fp_step(rng):
    k = rng.random()
    fd, fs1, fs2, fs3 = rfp(rng), rfp(rng), rfp(rng), rfp(rng)
    rd, rs1 = rint(rng), rint(rng)
    if k < 0.22:
        # Deliberate writeback burst: 2x I2F + FMISC + FMA in same window
        return [
            f"fmv.w.x {rfp(rng)}, {rint(rng)}",
            f"fmv.d.x {rfp(rng)}, {rint(rng)}",
            f"{rng.choice(['fsgnj.s', 'fsgnjn.s', 'fsgnj.d', 'fsgnjx.d'])} {rfp(rng)}, {rfp(rng)}, {rfp(rng)}",
            f"{rng.choice(FP_S_FMA)} {rfp(rng)}, {rfp(rng)}, {rfp(rng)}, {rfp(rng)}",
        ]
    elif k < 0.42:
        return [f"{rng.choice(FP_S_BIN)} {fd}, {fs1}, {fs2}"]
    elif k < 0.60:
        return [f"{rng.choice(FP_D_BIN)} {fd}, {fs1}, {fs2}"]
    elif k < 0.72:
        return [f"{rng.choice(FP_S_FMA + FP_D_FMA)} {fd}, {fs1}, {fs2}, {fs3}"]
    elif k < 0.82:
        return [f"{rng.choice(FP_CMP)} {rd}, {fs1}, {fs2}"]
    elif k < 0.90:
        op = rng.choice(["fmv.x.w", "fmv.x.d", "fclass.s", "fclass.d", "fcvt.w.s", "fcvt.l.d"])
        return [f"{op} {rd}, {fs1}"]
    elif k < 0.96:
        op = rng.choice(["fmv.w.x", "fmv.d.x", "fcvt.s.w", "fcvt.d.l"])
        return [f"{op} {fd}, {rs1}"]
    else:
        op = rng.choice(["fdiv.s", "fdiv.d", "fsqrt.s", "fsqrt.d"])
        if "sqrt" in op:
            return [f"{op} {fd}, {fs1}"]
        return [f"{op} {fd}, {fs1}, {fs2}"]


def gen_lsu_step(rng):
    # Narrow 64-byte window (offsets 0..56) to maximize STLF & cross-word overlap collisions!
    base = rng.choice(MEM_BASES)
    k = rng.random()
    if k < 0.35:
        # Store-then-load overlap burst at same or adjacent bytes
        off8 = rng.randrange(0, 56, 8)
        sub_off = off8 + rng.choice([0, 1, 2, 4])
        lines = []
        st_kind = rng.choice(["sd", "sw", "sh", "sb"])
        if st_kind == "sd":
            lines.append(f"sd {rint(rng)}, {off8}({base})")
        elif st_kind == "sw":
            lines.append(f"sw {rint(rng)}, {off8 + rng.choice([0, 4])}({base})")
        elif st_kind == "sh":
            lines.append(f"sh {rint(rng)}, {off8 + rng.choice([0, 2, 4, 6])}({base})")
        else:
            lines.append(f"sb {rint(rng)}, {sub_off}({base})")
        ld_kind = rng.choice(["ld", "lw", "lwu", "lh", "lhu", "lb", "lbu"])
        if ld_kind == "ld":
            lines.append(f"ld {rint(rng)}, {off8}({base})")
        elif ld_kind in ("lw", "lwu"):
            lines.append(f"{ld_kind} {rint(rng)}, {off8 + rng.choice([0, 4])}({base})")
        elif ld_kind in ("lh", "lhu"):
            lines.append(f"{ld_kind} {rint(rng)}, {off8 + rng.choice([0, 2, 4, 6])}({base})")
        else:
            lines.append(f"{ld_kind} {rint(rng)}, {sub_off}({base})")
        return lines
    elif k < 0.60:
        # Store burst (WBP / STQ pressure)
        off8 = rng.randrange(0, 48, 8)
        return [
            f"sd {rint(rng)}, {off8}({base})",
            f"sw {rint(rng)}, {off8 + 8}({base})",
            f"sh {rint(rng)}, {off8 + 12}({base})",
            f"sb {rint(rng)}, {off8 + 14}({base})",
        ]
    elif k < 0.78:
        # FP load/store
        off8 = rng.randrange(0, 56, 8)
        op = rng.choice(["fld", "fsd", "flw", "fsw"])
        return [f"{op} {rfp(rng)}, {off8}({base})"]
    elif k < 0.92:
        # Atomic AMO on aligned address in sandbox
        off8 = rng.randrange(0, 56, 8)
        amo = rng.choice(["amoadd.d", "amoswap.d", "amoxor.d", "amoand.d", "amoor.d",
                          "amoadd.w", "amoswap.w", "amoxor.w", "amomin.w", "amomaxu.w"])
        return [
            f"addi s9, {base}, {off8}",
            f"{amo} {rint(rng)}, {rint(rng)}, (s9)",
        ]
    else:
        # LR/SC pair (no IRQ in this block)
        off8 = rng.randrange(0, 56, 8)
        return [
            f"addi s9, {base}, {off8}",
            f"lr.d {rint(rng)}, (s9)",
            f"sc.d {rint(rng)}, {rint(rng)}, (s9)",
        ]


def gen_fe_step(rng, step_id):
    k = rng.random()
    if k < 0.50:
        # Short forward conditional branch skipping 1-3 instructions
        br = rng.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
        lbl = f"L_fwd_{step_id}"
        lines = [f"{br} {rint(rng)}, {rint(rng)}, {lbl}"]
        for _ in range(rng.randint(1, 3)):
            lines.extend(gen_alu_step(rng))
        lines.append(f"{lbl}:")
        return lines
    elif k < 0.78:
        # Bounded short backward loop (2-4 iterations using s11)
        lbl = f"L_lp_{step_id}"
        iters = rng.randint(2, 4)
        lines = [f"li s11, {iters}", f"{lbl}:"]
        lines.extend(gen_alu_step(rng))
        if rng.random() < 0.5:
            lines.extend(gen_lsu_step(rng)[:2])
        lines.append(f"addi s11, s11, -1")
        lines.append(f"bnez s11, {lbl}")
        return lines
    elif k < 0.94:
        # Local JAL call + return stub (tests RAS / BPU)
        lbl_fn = f"L_fn_{step_id}"
        lbl_end = f"L_end_{step_id}"
        return [
            f"jal ra, {lbl_fn}",
            f"j {lbl_end}",
            f"{lbl_fn}:",
            f"addi {rint(rng)}, {rint(rng)}, {rng.randint(-16, 15)}",
            f"ret",
            f"{lbl_end}:",
        ]
    else:
        return ["fence.i"]


def gen_priv_step(rng):
    k = rng.random()
    rd, rs1 = rint(rng), rint(rng)
    if k < 0.45:
        csr = rng.choice(["mscratch", "sscratch", "fflags", "frm"])
        op = rng.choice(["csrrw", "csrrs", "csrrc"])
        return [f"{op} {rd}, {csr}, {rs1}"]
    elif k < 0.75:
        # Controlled ecall (M-mode trap handler skips 4B and returns via mret)
        return [".option push", ".option norvc", "ecall", ".option pop"]
    elif k < 0.90:
        # Controlled illegal instruction (4B, M-mode trap handler skips 4B)
        return [".option push", ".option norvc", ".word 0xffffffff", ".option pop"]
    else:
        return ["sfence.vma"]


def generate(seed, profile, n_steps):
    rng = random.Random(seed)
    use_rvc = profile in ("fe_rvc", "mixed")
    lines = [
        f"/* Auto-generated RV64GC fuzz program: seed={seed} profile={profile} steps={n_steps} */",
        "    .option norelax",
        "    .option rvc" if use_rvc else "    .option norvc",
        '    .section .text.start,"ax",@progbits',
        "    .globl _start",
        "_start:",
        "    /* Install M-mode trap handler for controlled ecall / illegal-inst */",
        "    la   t0, fuzz_trap_handler",
        "    csrw mtvec, t0",
        "    /* Enable mstatus.FS = Initial (0x2000) */",
        "    li   t0, 0x2000",
        "    csrs mstatus, t0",
        "    /* Sandbox bases (s0, s1 are 16 KiB apart -> same DCache set) */",
        "    li   s0, 0x80020000",
        "    li   s1, 0x80024000",
        "    /* Pre-fill 64B sandbox windows with deterministic data */",
    ]
    for off in range(0, 64, 8):
        v = rng.getrandbits(64)
        lines.append(f"    li   t0, 0x{v:016x}")
        lines.append(f"    sd   t0, {off}(s0)")
        lines.append(f"    sd   t0, {off}(s1)")
    lines.append("    /* Initialize integer and FP registers */")
    edge_ints = [0, 1, -1, 0x7fffffff, -0x80000000, 0x123456789abcdef0, 0x3f800000, 0xbf800000, 0x40000000]
    for r in INT_REGS:
        v = rng.choice(edge_ints) if rng.random() < 0.4 else rng.getrandbits(64)
        lines.append(f"    li   {r}, {v if v < 0 else hex(v)}")
    fp_inits = [0x3ff0000000000000, 0xbff0000000000000, 0x4000000000000000,
                0x0000000000000000, 0xffffffff3f800000, 0xffffffffbf800000, 0xffffffff40400000]
    for fr in FP_REGS:
        v = rng.choice(fp_inits)
        lines.append(f"    li   t0, 0x{v:016x}")
        lines.append(f"    fmv.d.x {fr}, t0")

    weights_map = {
        "alu_fp":    (0.45, 0.45, 0.05, 0.05, 0.00),
        "lsu_stlf":  (0.15, 0.05, 0.70, 0.10, 0.00),
        "fe_rvc":    (0.25, 0.10, 0.15, 0.50, 0.00),
        "priv_trap": (0.25, 0.15, 0.20, 0.10, 0.30),
        "mixed":     (0.28, 0.22, 0.26, 0.18, 0.06),
    }
    w_alu, w_fp, w_lsu, w_fe, w_priv = weights_map[profile]

    for sid in range(n_steps):
        lines.append(f"# STEP_BEGIN {sid}")
        r = rng.random()
        if r < w_alu:
            body = gen_alu_step(rng)
        elif r < w_alu + w_fp:
            body = gen_fp_step(rng)
        elif r < w_alu + w_fp + w_lsu:
            body = gen_lsu_step(rng)
        elif r < w_alu + w_fp + w_lsu + w_fe:
            body = gen_fe_step(rng, sid)
        else:
            body = gen_priv_step(rng)
        for inst in body:
            lines.append(inst if inst.endswith(":") or inst.startswith(".") else f"    {inst}")
        lines.append(f"# STEP_END {sid}")

    lines.extend([
        "    li   a0, 0",
        "    ebreak",
        "",
        "    .balign 4",
        "fuzz_trap_handler:",
        "    /* Advance mepc past trapping 4B instruction (ecall / illegal .word) */",
        "    csrr s10, mepc",
        "    addi s10, s10, 4",
        "    csrw mepc, s10",
        "    mret",
    ])
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--profile", choices=["mixed", "alu_fp", "lsu_stlf", "fe_rvc", "priv_trap"], default="mixed")
    ap.add_argument("--steps", type=int, default=120)
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()
    with open(args.out, "w") as fp:
        fp.write(generate(args.seed, args.profile, args.steps))


if __name__ == "__main__":
    main()
