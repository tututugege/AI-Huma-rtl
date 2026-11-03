#!/usr/bin/env python3
"""Mutation list for the lsu module; runs scripts/mutcheck.sh for each (every mutant must FAIL on at least one trace).
usage: python3 tests/lsu/mutants.py [first_index [last_index]]   env TRACES overrides the trace list"""
import os, subprocess, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
D = 'rtl/backend/lsu/'
M = [
 # (id, file, old, new, description)
 ('M01', 'lsu_stlf_match.sv', "{1'b0, RIW'(RIW'(s) - stq_head)} < age_dist", "{1'b0, RIW'(RIW'(s) - stq_head)} <= age_dist", 'STLF: stores up to and including the snapshot boundary count as older'),
 ('M02', 'lsu_stlf_match.sv', "assign rev_pos[j] = decider_pos[SQ-1-j];", "assign rev_pos[j] = decider_pos[j];", 'STLF: wrong decider selection (scan direction)'),
 ('M03', 'lsu_alloc.sv', "stq_req[i] && stq_count_i + rank[i] < RCW'(SQ)", "stq_req[i] && stq_count_i + rank[i] < RCW'(SQ - 1)", 'STQ alloc capacity one short'),
 ('M04', 'lsu_dc_req_ld.sv', "w_p[p] < RWW'(2)", "w_p[p] < RWW'(1)", 'load replay countdown issues one cycle later'),
 ('M05', 'lsu_dc_resp_ld.sv', "rank_full[p] < RCW'(NLD)", "rank_full[p] < RCW'(NLD + 1)", 'MSHR_FULL wake-up limit +1'),
 ('M06', 'lsu_stq_commit.sv', "expect_idx[i] = stq_head + RIW'(stq_ccount_i) + RIW'(n_acc[i]);", "expect_idx[i] = stq_head + RIW'(stq_ccount_i);", 'store commit ignores earlier commits of the same cycle'),
 ('M07', 'lsu_cur_info.sv', "if (ldq_busy <= AW'(LQ) && ldq_free_by_busy < ldq_empty_cnt)", "if (ldq_free_by_busy < ldq_empty_cnt)", 'ldq_free: no unsigned-wrap handling'),
 ('M08', 'lsu_dc_req_st.sv', "assign done_after[i] = done_w[i] || sup_done[i];", "assign done_after[i] = done_w[i];", 'older suppressed store does not unblock younger same-address store'),
 ('M09', 'lsu_flush_stq.sv', "for (int j = 0; j < SQ; j++) if (hit_first[j]) count_m = RCW'(j);", "for (int j = 0; j < SQ; j++) if (hit_first[j]) count_m = RCW'(j) + RCW'(1);", 'mispredict keeps one STQ entry too many'),
 ('M10', 'lsu_wb_ldq.sv', "assign acc[p]  = cand[p] && rank[p] + n_sc < RCW'(NLD);", "assign acc[p]  = cand[p] && rank[p] < RCW'(NLD);", 'load write-back ignores ports taken by SC'),
 ('M11', 'lsu_pkg.sv', "(a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX))", "(a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX) && 1'b0)", 'cacheable window 1 treated as MMIO'),
 ('M12', 'lsu_pkg.sv', "2'b01:   r = f3[2] ? {16'b0, sh[15:0]} : {{16{sh[15]}}, sh[15:0]};", "2'b01:   r = f3[2] ? {{16{sh[15]}}, sh[15:0]} : {16'b0, sh[15:0]};", 'LH/LHU extension swapped'),
 ('M13', 'lsu_pkg.sv', "if (s_addr <= l_addr && s_end >= l_end) return 2'd1;", "if (s_addr <= l_addr && s_end > l_end) return 2'd1;", 'STLF cover test off by one'),
 ('M14', 'lsu_dc_resp_ld.sv', "wd_wait_v1[s] = rsp_replay[i][1] ? REPLAY_WAIT : '0;", "wd_wait_v1[s] = (rsp_replay[i] != '0) ? REPLAY_WAIT : '0;", 'CONFLICT replay also waits'),
 ('M15', 'lsu_retire.sv', "assign window    = committed > RCW'(WIN) ? RCW'(WIN) : committed;", "assign window    = committed;", 'retire window not limited'),
 ('M16', 'lsu_pkg.sv', "else if (w2 + 31'd1 == w1) return ((m1 << 4) & m2) != 9'b0;", "else if (w2 + 31'd1 == w1) return 1'b0;", 'CheckAddr: no overlap with the next word'),
 ('M17', 'lsu_mmio_in.sv', "assign load_room = finish_i.count < RCW'(LQ);", "assign load_room = 1'b1;", 'MMIO load response ignores finish room'),
 ('M18', 'lsu_unc.sv', "st_st_pre_flush[idx2] == ST_WAIT_MMIO_RESP) : v2;", "st_st_pre_flush[idx2] != ST_EMPTY) : v2;", 'rob flush keeps the MMIO store regardless of its state'),
 ('M19', 'lsu_lrsc.sv', "assign alive   = valid_i && !pf_clear &&", "assign alive   = valid_i && !(pf_clear && mispred) &&", 'page fault does not kill the reservation'),
 ('M20', 'lsu_stlf_chain.sv', "mm_go   = mm && mmio_go[p] && !unc[p];", "mm_go   = mm && mmio_go[p];", 'two MMIO loads can take the uncached unit in one cycle'),
 ('M21', 'lsu_tlb_resp_ld.sv', "assign acc_stlf[p] = cand_stlf[p] && rank_stlf[p] < RCW'(NLD) &&", "assign acc_stlf[p] = cand_stlf[p] &&", 'STLF queue entry limit per cycle ignored'),
 ('M22', 'lsu_stlf_match.sv', "assign decider[s]  = older[s] && !st_suppress[s] &&", "assign decider[s]  = older[s] && (!st_suppress[s] || st_is_lrsc[s]) &&", 'cancelled stores can forward / block'),
 ('M23', 'lsu_flush_ld.sv', "assign ld_br_mask_o[e] = ld_st_q[e] != LD_EMPTY ? ld_br_mask_i[e] & ~clear_mask : ld_br_mask_i[e];", "assign ld_br_mask_o[e] = ld_st_q[e] == LD_EMPTY ? ld_br_mask_i[e] & ~clear_mask : ld_br_mask_i[e];", 'clear_mask not applied to LDQ'),
 ('M24', 'lsu_dc_req_st.sv', "assign cand[i]       = in_q[i] && committed_w[i] && !wdr_w[i];".replace('in_q','in_w'), "assign cand[i]       = in_w[i] && committed_w[i] && (!wdr_w[i] || mmio_w[i]);", 'store may reissue in the cycle its replay response arrives'),
 ('M25', 'lsu_exe_in_ld.sv', "ld_rob_flag[req_ldq_idx[p]] == req_rob_flag[p];", "ld_rob_flag[req_ldq_idx[p]] != req_rob_flag[p];", 'load request ignores the rob flag'),
]

def main():
    lo = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    hi = int(sys.argv[2]) if len(sys.argv) > 2 else len(M)
    traces = os.environ.get('TRACES', 'dhrystone coremark memory-stress stlf-overlap-boundary atomic-boundary timer-mmio vm_pagefault_test unalign dcache-mshr-pressure memory-boundary').split()
    for i, (mid, f, old, new, desc) in enumerate(M, 1):
        if i < lo or i > hi: continue
        r = subprocess.run(['bash', 'scripts/mutcheck.sh', ROOT, 'lsu', D + f, old, new] + traces, cwd=ROOT, capture_output=True, text=True)
        out = r.stdout + r.stderr
        fails = [l for l in out.split('\n') if 'MISMATCH' in l or 'FAIL' in l]
        first = next((l for l in out.split('\n') if 'MISMATCH' in l), '')
        status = 'CAUGHT' if fails else ('SURVIVED' if 'PASS' in out else 'BUILD-ERROR?')
        print(f'{mid} {status}: {desc}\n    {first.strip()[:150]}', flush=True)
        if status != 'CAUGHT': print(out[-600:])

main()
