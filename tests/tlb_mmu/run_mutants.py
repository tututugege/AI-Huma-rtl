#!/usr/bin/env python3
"""Mutation check for tlb_mmu: apply one textual mutation to a copy of rtl/, rebuild the replayer, replay (1) the real-program traces
(vm tests + gate tests + big programs), (2) the random traces. Prints, per mutant, which set caught it first and the mismatching field.
usage: run_mutants.py [mutant-name...]   (default: all)"""
import glob, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
P = 'rtl/backend/tlb_mmu/'
# name: (file, old, new)
M = {
 'perm_sum':      (P+'tlb_mmu_pkg.sv', "(access_type == ACC_FETCH || !sum)", "(access_type == ACC_FETCH || sum)"),
 'perm_dirty':    (P+'tlb_mmu_pkg.sv', "         || !a\n         || (access_type == ACC_STORE && !d);", "         || !a\n         || (access_type == ACC_STORE && !d && 1'b0);"),
 'perm_mxr':      (P+'tlb_mmu_pkg.sv', "!r && !(mxr && x)", "!r && !(mxr || x)"),
 'perm_user':     (P+'tlb_mmu_pkg.sv', "(eff_priv == 2'd0 && !u)", "(eff_priv == 2'd0 && u)"),
 'perm_accessed': (P+'tlb_mmu_pkg.sv', "         || !a\n", "         || (!a && access_type == ACC_STORE)\n"),
 'paddr_mega':    (P+'tlb_mmu_pkg.sv', "{ppn[PPN_W-1:VPN_PART_W], vaddr_low}", "{ppn[PPN_W-1:VPN_PART_W], vaddr_low[11:0], vaddr_low[21:12]}"),
 'match_global':  (P+'tlb_mmu_pkg.sv', "(t.global_page || t.asid == asid)", "(t.global_page && 1'b0 || t.asid == asid)"),
 'match_asid':    (P+'tlb_mmu_pkg.sv', "(t.global_page || t.asid == asid)", "(t.global_page || t.asid == asid || t.asid != asid)"),
 'match_level':   (P+'tlb_mmu_pkg.sv', "(t.level || t.vpn0 ==", "(t.level && 1'b0 || t.vpn0 =="),
 'priv_mprv':     (P+'tlb_mmu_pkg.sv', "&& mprv) ? mpp : privilege", "&& mprv) ? privilege : mpp"),
 'repl_stuck':    (P+'tlb_mmu_store.sv', "repl_d = repl_q + SLOT_W'(1);", "repl_d = repl_q;"),
 'fence_repl':    (P+'tlb_mmu_store.sv', "      repl_d = '0;\n", "\n"),
 'fence_valid':   (P+'tlb_mmu_store.sv', "      entry_valid_d = '0;\n", "\n"),
 'lookup_prio':   (P+'tlb_mmu_lookup.sv', ".sel(match_first)", ".sel(match_first | match)"),
 'early_perm':    (P+'tlb_mmu_early.sv', "!resp.fault && perm_pass", "!resp.fault && (perm_pass || 1'b1)"),
 'early_type':    (P+'tlb_mmu_early.sv', "walk.access_type, walk.eff_priv", "walk.access_type & 2'd1, walk.eff_priv"),
 'cancel_consume':(P+'tlb_mmu_core.sv', "cancel ? early_done : early_refill_ok", "cancel ? (early_done && early_refill_ok) : early_refill_ok"),
 'cancel_walk':   (P+'tlb_mmu_core.sv', "walk_d = (fence || cancel) ? '0", "walk_d = (fence) ? '0"),
 'cancel_refill': (P+'tlb_mmu_core.sv', "chain_start.refill_valid = early_refill_ok;", "chain_start.refill_valid = early_refill_ok && !cancel;"),
 'consumed_early':(P+'tlb_mmu_core.sv', "ptw_resp_consumed = early_consume || (|lane_resp_consumed)", "ptw_resp_consumed = (|lane_resp_consumed)"),
 'root_ppn':      (P+'tlb_mmu_core.sv', "chain[LANES].walk.satp[21:0]", "chain[LANES].walk.satp[22:1]"),
 'walk_satp':     (P+'tlb_mmu_lane.sv', " || chain_in.walk.satp != satp)", ")"),
 'walk_page':     (P+'tlb_mmu_lane.sv', "chain_in.walk.vpn != vpn ||", "chain_in.walk.vpn[VPN_W-1:1] != vpn[VPN_W-1:1] ||"),
 'walk_resp_vpn': (P+'tlb_mmu_lane.sv', "resp_for_walk = ptw_resp.vpn == vpn;", "resp_for_walk = ptw_resp.vpn[VPN_W-1:1] == vpn[VPN_W-1:1];"),
 'walk_priv':     (P+'tlb_mmu_lane.sv', "eff_priv: eff_priv,\n", "eff_priv: privilege,\n"),
 'refill_asid':   (P+'tlb_mmu_lane.sv', "asid: asid, level: ptw_resp.level", "asid: '0, level: ptw_resp.level"),
 'resp_hide':     (P+'tlb_mmu_lane.sv', "          walk_chain.resp_valid = 1'b0;\n        end\n      end else if", "        end\n      end else if"),
 'bare_mode':     (P+'tlb_mmu_lane.sv', "bare = eff_priv == 2'd3 || !satp[31];", "bare = eff_priv == 2'd3;"),
 'refill_bypass': (P+'tlb_mmu_lane.sv', "hit = refill_match || table_hit;", "hit = table_hit;"),
 'resp_fault':    (P+'tlb_mmu_lane.sv', "if (ptw_resp.fault || !resp_perm_ok)", "if (ptw_resp.fault || (!resp_perm_ok && 1'b0))"),
 'lane_order':    (P+'tlb_mmu_core.sv', "lane < LD_LANES ? ACC_LOAD : ACC_STORE", "lane < LD_LANES ? ACC_STORE : ACC_LOAD"),
 'top_cancel':    (P+'tlb_mmu.sv', ".cancel(rob_bcast_flush || dec_bcast_mispred)", ".cancel(rob_bcast_flush || (dec_bcast_mispred && 1'b0))"),
 'top_fence_prio':(P+'tlb_mmu.sv', ".fence(rob_bcast_fence)", ".fence(rob_bcast_fence && !rob_bcast_flush)"),
 'ld_idx':        (P+'tlb_mmu.sv', "assign ldq_resp_entry_idx[i] = ldq_req_entry_idx[i];\n    assign ldq_resp_wait_idx[i] = ldq_req_wait_idx[i];", "assign ldq_resp_entry_idx[i] = ldq_req_wait_idx[i];\n    assign ldq_resp_wait_idx[i] = ldq_req_entry_idx[i];"),
}

def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)

def main():
    names = sys.argv[1:] or list(M)
    real = sorted(glob.glob(f'{ROOT}/traces/tlb_mmu/*.trc'))
    rnd = [t for t in real if os.path.basename(t).startswith('rand_')]
    rnd_main = [t for t in rnd if 'stale' not in t]
    rnd_stale = [t for t in rnd if 'stale' in t]
    real = [t for t in real if t not in rnd]
    vm = [t for t in real if os.path.basename(t).startswith('vm_')]
    for n in names:
        f, old, new = M[n]
        T = tempfile.mkdtemp(prefix='tlbmut_')
        shutil.copytree(f'{ROOT}/rtl', f'{T}/rtl'); shutil.copytree(f'{ROOT}/spec', f'{T}/spec')
        p = f'{T}/{f}'
        s = open(p).read()
        if old not in s:
            print(f'{n}: PATTERN NOT FOUND'); continue
        open(p, 'w').write(s.replace(old, new, 1))
        files = [f'{T}/{x}' for x in run(['bash', f'{ROOT}/scripts/rtl_files.sh', T], ROOT).stdout.split()]
        b = run(['bash', f'{ROOT}/scripts/hbuild.sh', f'{T}/spec/tlb_mmu.io', f'{T}/build'] + files, ROOT)
        if 'BUILD FAILED' in b.stdout + b.stderr:
            print(f'{n}: BUILD FAILED'); print(b.stdout[-600:]); continue
        res = None
        for label, group in (('real-vm', vm), ('real-all', real), ('random', rnd_main), ('random-stale', rnd_stale)):
            for t in group:
                r = run([f'{T}/build/replay', t, '--max-fail', '1'], ROOT)
                out = r.stdout
                if 'FAIL' in out:
                    m = re.search(r'MISMATCH rec=(\d+) cycle=(\d+) (\w+)', out)
                    res = f'{label}: {os.path.basename(t)} rec={m.group(1)} field={m.group(3)}' if m else f'{label}: {os.path.basename(t)}'
                    break
            if res: break
        print(f'{n}: ' + (res or 'SURVIVED'), flush=True)
        shutil.rmtree(T)

main()
