#!/usr/bin/env python3
"""Delta-debugging minimizer for failing RV64GC fuzz programs (removes # STEP_BEGIN..# STEP_END blocks)."""
import argparse
import os
import re
import shutil
import subprocess
import tempfile

FUZZ_DIR = os.path.dirname(os.path.abspath(__file__))
RTL_ROOT = os.path.abspath(os.path.join(FUZZ_DIR, "..", ".."))
LINK_LD  = os.path.join(RTL_ROOT, "programs", "directed", "link.ld")

CC = shutil.which("clang") or shutil.which("clang-18") or "clang"
LLD = shutil.which("ld.lld") or "ld.lld"
OBJCOPY = shutil.which("llvm-objcopy") or shutil.which("llvm-objcopy-18") or shutil.which("objcopy")


def parse_steps(text):
    lines = text.splitlines()
    prefix, steps, suffix = [], [], []
    cur, in_step, seen_any = [], False, False
    for ln in lines:
        if ln.startswith("# STEP_BEGIN "):
            in_step = True
            seen_any = True
            cur = [ln]
        elif ln.startswith("# STEP_END "):
            cur.append(ln)
            steps.append(cur)
            cur = []
            in_step = False
        elif in_step:
            cur.append(ln)
        elif not seen_any:
            prefix.append(ln)
        else:
            suffix.append(ln)
    return prefix, steps, suffix


def fails_on(tb, src_text, max_cycles, strict, match_pat):
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "p.S")
        obj = os.path.join(td, "p.o")
        elf = os.path.join(td, "p.elf")
        binf = os.path.join(td, "p.bin")
        with open(src, "w") as fp:
            fp.write(src_text)
        if subprocess.run([CC, "--target=riscv64-unknown-elf",
                           "-march=rv64imafdc_zba_zbb_zbc_zbs_zicsr_zifencei",
                           "-mabi=lp64d", "-c", src, "-o", obj], capture_output=True).returncode != 0:
            return False
        if subprocess.run([LLD, "-m", "elf64lriscv", "--no-relax", "-T", LINK_LD, obj, "-o", elf],
                          capture_output=True).returncode != 0:
            return False
        if subprocess.run([OBJCOPY, "-O", "binary", elf, binf], capture_output=True).returncode != 0:
            return False
        env = os.environ.copy()
        env["SOC_TB_FM"] = "1"
        if strict:
            env["SOC_TB_FM_STRICT"] = "1"
        try:
            r = subprocess.run([tb, binf, str(max_cycles)], env=env, capture_output=True, text=True, timeout=30)
            out = r.stdout + "\n" + r.stderr
        except subprocess.TimeoutExpired:
            out = "TIMEOUT"
        if match_pat:
            return bool(re.search(match_pat, out))
        return bool(re.search(r"^\[FM\].*(rtl=|rejects)|%Error|Assertion failed|\[SVA_|\[FPWB\]|NO EBREAK|TIMEOUT", out, re.M))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tb", required=True)
    ap.add_argument("--src", required=True, help="Failing prog.S")
    ap.add_argument("-o", "--out", required=True, help="Minimized output .S")
    ap.add_argument("--max-cycles", type=int, default=60000)
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--pattern", default="", help="Optional regex that must still match in failure output")
    args = ap.parse_args()

    with open(args.src) as fp:
        prefix, steps, suffix = parse_steps(fp.read())

    def render(kept):
        out = list(prefix)
        for st in kept:
            out.extend(st)
        out.extend(suffix)
        return "\n".join(out) + "\n"

    if not fails_on(args.tb, render(steps), args.max_cycles, args.strict, args.pattern):
        print("ERROR: original program does not reproduce failure!")
        return

    print(f"Start minimizing: {len(steps)} steps")
    kept = list(steps)
    n = 2
    while len(kept) >= 2:
        chunk = max(1, len(kept) // n)
        reduced = False
        i = 0
        while i < len(kept):
            cand = kept[:i] + kept[i + chunk:]
            if cand and fails_on(args.tb, render(cand), args.max_cycles, args.strict, args.pattern):
                kept = cand
                print(f"  reduced -> {len(kept)} steps", flush=True)
                reduced = True
            else:
                i += chunk
        if not reduced:
            if n >= len(kept):
                break
            n = min(len(kept), n * 2)

    with open(args.out, "w") as fp:
        fp.write(render(kept))
    print(f"Done: {len(steps)} -> {len(kept)} steps written to {args.out}")


if __name__ == "__main__":
    main()
