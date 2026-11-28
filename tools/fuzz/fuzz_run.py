#!/usr/bin/env python3
"""Parallel RV64GC fuzzer runner against RTL soc_tb (with FM difftest + SVA + optional strict CSR/MMIO)."""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import time

FUZZ_DIR = os.path.dirname(os.path.abspath(__file__))
RTL_ROOT = os.path.abspath(os.path.join(FUZZ_DIR, "..", ".."))
LINK_LD  = os.path.join(RTL_ROOT, "programs", "directed", "link.ld")
GEN_PY   = os.path.join(FUZZ_DIR, "gen_prog.py")

CC = shutil.which("clang") or shutil.which("clang-18") or "clang"
LLD = shutil.which("ld.lld") or "ld.lld"
OBJCOPY = shutil.which("llvm-objcopy") or shutil.which("llvm-objcopy-18") or shutil.which("objcopy")


def run_seed(args_tuple):
    seed, profile, steps, tb, spike_fm, out_dir, max_cycles, strict = args_tuple
    work = os.path.join(out_dir, "tmp", f"s{seed}_{profile}")
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "prog.S")
    obj = os.path.join(work, "prog.o")
    elf = os.path.join(work, "prog.elf")
    binf = os.path.join(work, "prog.bin")
    logf = os.path.join(work, "run.log")

    # 1. Generate
    r = subprocess.run([sys.executable, GEN_PY, "--seed", str(seed), "--profile", profile,
                        "--steps", str(steps), "-o", src], capture_output=True, text=True)
    if r.returncode != 0:
        return (seed, profile, "GEN_FAIL", r.stderr.strip()[:120], 0, 0)

    # 2. Assemble & link
    r = subprocess.run([CC, "--target=riscv64-unknown-elf", "-march=rv64imafdc_zba_zbb_zbc_zbs_zicsr_zifencei",
                        "-mabi=lp64d", "-c", src, "-o", obj], capture_output=True, text=True)
    if r.returncode != 0:
        return (seed, profile, "CC_FAIL", r.stderr.strip().splitlines()[0] if r.stderr else "", 0, 0)
    r = subprocess.run([LLD, "-m", "elf64lriscv", "--no-relax", "-T", LINK_LD, obj, "-o", elf],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return (seed, profile, "LD_FAIL", r.stderr.strip().splitlines()[0] if r.stderr else "", 0, 0)
    r = subprocess.run([OBJCOPY, "-O", "binary", elf, binf], capture_output=True, text=True)
    if r.returncode != 0:
        return (seed, profile, "OC_FAIL", "", 0, 0)

    # 3. Run either function-model vs Spike (--spike-fm) or RTL vs function-model (--tb)
    env = os.environ.copy()
    if spike_fm:
        env["REF_UNBUF"] = "1"
        try:
            r = subprocess.run([spike_fm, "--image", binf, "--diff"], env=env, capture_output=True, text=True, timeout=30)
            out_txt = r.stdout + "\n" + r.stderr
        except subprocess.TimeoutExpired:
            out_txt = "TIMEOUT\n"
        with open(logf, "w") as fp:
            fp.write(out_txt)
        ok = ("Success" in out_txt) and ("MISMATCH" not in out_txt) and ("TIMEOUT" not in out_txt)
        if ok:
            shutil.rmtree(work, ignore_errors=True)
            return (seed, profile, "PASS", "", 0, steps)
        fail_dir = os.path.join(out_dir, "failures", f"s{seed}_{profile}")
        os.makedirs(os.path.dirname(fail_dir), exist_ok=True)
        if os.path.exists(fail_dir):
            shutil.rmtree(fail_dir)
        shutil.move(work, fail_dir)
        reason = ""
        for line in out_txt.splitlines():
            if any(k in line for k in ("MISMATCH", "Reason", "FAIL", "TIMEOUT", "error")):
                reason = line.strip()[:140]
                break
        return (seed, profile, "FAIL", reason or "FM_SPIKE_FAIL", 0, 0)

    env["SOC_TB_FM"] = "1"
    if strict:
        env["SOC_TB_FM_STRICT"] = "1"
    try:
        r = subprocess.run([tb, binf, str(max_cycles)], env=env, capture_output=True, text=True, timeout=60)
        out_txt = r.stdout + "\n" + r.stderr
    except subprocess.TimeoutExpired:
        out_txt = "TIMEOUT\n"

    with open(logf, "w") as fp:
        fp.write(out_txt)

    m = re.search(r"sim-time\(cycle\)=\s*(\d+),\s*committed=\s*(\d+)", out_txt)
    cyc = int(m.group(1)) if m else 0
    cmt = int(m.group(2)) if m else 0
    fm_err = bool(re.search(r"^\[FM\].*(rtl=|rejects)", out_txt, re.M))
    sva_err = bool(re.search(r"%Error|Assertion failed|\[SVA_|\[FPWB\]", out_txt))
    no_ebreak = ("NO EBREAK" in out_txt) or ("TIMEOUT" in out_txt) or (m is None)

    if not fm_err and not sva_err and not no_ebreak:
        shutil.rmtree(work, ignore_errors=True)
        return (seed, profile, "PASS", "", cyc, cmt)

    # Save failing reproducer
    fail_dir = os.path.join(out_dir, "failures", f"s{seed}_{profile}")
    os.makedirs(os.path.dirname(fail_dir), exist_ok=True)
    if os.path.exists(fail_dir):
        shutil.rmtree(fail_dir)
    shutil.move(work, fail_dir)
    reason = ""
    for line in out_txt.splitlines():
        if any(k in line for k in ("[FM]", "[SVA_", "[FPWB]", "%Error", "Assertion failed", "NO EBREAK", "TIMEOUT")):
            reason = line.strip()[:140]
            break
    return (seed, profile, "FAIL", reason, cyc, cmt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tb", default="", help="Path to core_tb binary (tb/core/build.sh with SOC_FM=1; RTL vs function-model)")
    ap.add_argument("--spike-fm", default="", help="Path to Spike-checked function-model a.out (function-model vs Spike)")
    ap.add_argument("--out", required=True, help="Output directory")
    ap.add_argument("--seeds", type=int, default=100, help="Number of seeds to run")
    ap.add_argument("--start-seed", type=int, default=1)
    ap.add_argument("--profile", default="all", choices=["all", "mixed", "alu_fp", "lsu_stlf", "fe_rvc", "priv_trap"])
    ap.add_argument("--steps", type=int, default=120, help="Random steps per program")
    ap.add_argument("--max-cycles", type=int, default=60000)
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--strict", action="store_true", help="Enable SOC_TB_FM_STRICT=1")
    args = ap.parse_args()
    if not args.tb and not args.spike_fm:
        ap.error("must provide either --tb or --spike-fm")

    os.makedirs(args.out, exist_ok=True)
    profiles = ["mixed", "alu_fp", "lsu_stlf", "fe_rvc", "priv_trap"] if args.profile == "all" else [args.profile]
    tasks = []
    for i in range(args.seeds):
        seed = args.start_seed + i
        prof = profiles[i % len(profiles)]
        tasks.append((seed, prof, args.steps, args.tb, args.spike_fm, args.out, args.max_cycles, args.strict))

    t0 = time.time()
    n_pass = n_fail = n_other = tot_cmt = tot_cyc = 0
    fails = []
    with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for seed, prof, st, reason, cyc, cmt in ex.map(run_seed, tasks):
            tot_cyc += cyc
            tot_cmt += cmt
            if st == "PASS":
                n_pass += 1
            elif st == "FAIL":
                n_fail += 1
                fails.append((seed, prof, reason))
                print(f"[FAIL] seed={seed} profile={prof}: {reason}", flush=True)
            else:
                n_other += 1
                print(f"[{st}] seed={seed} profile={prof}: {reason}", flush=True)

    el = time.time() - t0
    print(f"== FUZZ SUMMARY: PASS={n_pass} FAIL={n_fail} ERR={n_other} | "
          f"total_commits={tot_cmt} total_cycles={tot_cyc} | {el:.1f}s ({args.seeds/max(el,0.1):.1f} seeds/s) ==")
    if fails:
        print(f"Failing reproducers saved under: {os.path.join(args.out, 'failures')}")
        sys.exit(1)


if __name__ == "__main__":
    main()
