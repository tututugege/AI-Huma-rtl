#!/usr/bin/env python3
"""Mutation check of the lsu module with ONE build: every mutant is guarded in an RTL copy by `(mut_sel == K) ? mutated : original`
(mut_sel comes from $TTG_MUT through a DPI call; inside lsu_pkg functions the DPI call is made directly), so the whole check is
one Verilator build plus whole-program lock-step runs (pattern of scripts/mut_dcache.py / mut_backtop_fast.py).
Screening: each mutant runs on a few short programs (first mismatch kills it); survivors are re-run on up to 12 short programs x 150k cycles.

usage: python3 tests/lsu/mut_lsu.py [--jobs N] [--only K,K,..] [--extra]      env REFSIM (default: refsim_tap)
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
D = 'rtl/backend/lsu/'
G = '/Users/ruyaoh/personal/AI-Huma/trace-model/build'
# (name, file, original expression text, mutated expression text) -- the original text must occur in the file
M = [
 # --- package helpers
 ('pkg.stlf-cover-off-by-one', 'lsu_pkg.sv', "s_end >= l_end", "s_end > l_end"),
 ('pkg.stlf-partial-as-disjoint', 'lsu_pkg.sv', 'l_end <= s_addr || l_addr >= s_end', 'l_end <= s_addr'),
 ('pkg.lh-lhu-swapped', 'lsu_pkg.sv', "r = f3[2] ? {16'b0, sh[15:0]} : {{16{sh[15]}}, sh[15:0]};", "r = f3[2] ? {{16{sh[15]}}, sh[15:0]} : {16'b0, sh[15:0]};"),
 ('pkg.lb-offset-ignored', 'lsu_pkg.sv', "sh = raw >> {off, 3'b000};", "sh = raw;"),
 ('pkg.mmio-window1', 'lsu_pkg.sv', "(a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX))", "(a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX) && 1'b0)"),
 ('pkg.checkaddr-next-word', 'lsu_pkg.sv', "return ((m1 << 4) & m2) != 9'b0;", "return 1'b0;"),
 ('pkg.checkaddr-prev-word', 'lsu_pkg.sv', "return (m1 & (m2 << 4)) != 9'b0;", "return 1'b0;"),
 ('pkg.store-strb-half', 'lsu_pkg.sv', "return 5'b00011 << off;", "return 5'b00001 << off;"),
 ('pkg.align-store-byte', 'lsu_pkg.sv', "b = {24'b0, data[7:0]} << {off, 3'b000};", "b = {24'b0, data[7:0]};"),
 ('pkg.stq-alive-inclusive', 'lsu_pkg.sv', "return {1'b0, RIW'(idx - head)} < count;", "return {1'b0, RIW'(idx - head)} <= count;"),
 ('ring.pop-live-entry', 'lsu_pkg.sv', "n_pop = RCW'(p);", "n_pop = RCW'(p) + RCW'(1);"),
 ('ring.kp-no-kill', 'lsu_pkg.sv', '!op.keep_w[p]', "1'b0"),
 ('ring.append-slot-ignores-rank', 'lsu_pkg.sv', "slot = a.head + RIW'(a.count) + RIW'(n_app);", "slot = a.head + RIW'(a.count);"),
 ('ring.flush-keeps-count', 'lsu_pkg.sv', "a.count = '0;", 'a.count = a.count;'),
 # --- queue logic
 ('curinfo.ldq-free-no-wrap-check', 'lsu_cur_info.sv', "ldq_busy <= AW'(LQ)", "1'b1"),
 ('curinfo.stq-free-no-wrap-check', 'lsu_cur_info.sv', "stq_busy <= AW'(SQ)", "1'b1"),
 ('curinfo.stq-busy-uses-wait-only', 'lsu_cur_info.sv', "wait_mmu_stq_count_q > mmu_done_count_q ? wait_mmu_stq_count_q : mmu_done_count_q", "wait_mmu_stq_count_q"),
 ('commit.ignores-earlier-commits', 'lsu_stq_commit.sv', "expect_idx[i] = stq_head + RIW'(stq_ccount) + RIW'(n_acc[i]);", "expect_idx[i] = stq_head + RIW'(stq_ccount);"),
 ('commit.lr-counts-as-store', 'lsu_stq_commit.sv', "cm_amo_op[i] != AMO_LR", "1'b1"),
 ('commit.ccount-no-saturate', 'lsu_stq_commit.sv', "assign ccount_cm = (stq_ccount + n_acc[NCM] > RCW'(SQ)) ? RCW'(SQ) : stq_ccount + n_acc[NCM];", 'assign ccount_cm = stq_ccount + n_acc[NCM];'),
 ('commit.state-not-checked', 'lsu_stq_commit.sv', 'st_q[cm_stq_idx[i]] == ST_WAIT_COMMIT', "1'b1"),
 ('mmioin.ignores-finish-room', 'lsu_mmio_in.sv', "assign load_room = fin_count_q < RCW'(LQ);", "assign load_room = 1'b1;"),
 ('mmioin.load-keeps-unit-if-not-waiting', 'lsu_mmio_in.sv', "assign load_done = fire && unc_is_load && load_room;", "assign load_done = fire && unc_is_load && load_room && ld_st_q[unc_idx] == LD_WAIT_MMIO_RESP;"),
 ('mmioin.store-hit-no-state-check', 'lsu_mmio_in.sv', 'st_st_q[unc_idx] == ST_WAIT_MMIO_RESP', "1'b1"),
 ('dcresp-ld.wake-full-limit-plus1', 'lsu_dc_resp_ld.sv', "rank_full[p] < RCW'(NLD)", "rank_full[p] < RCW'(NLD + 1)"),
 ('dcresp-ld.wake-hit-any-line', 'lsu_dc_resp_ld.sv', "fld_q[idx_w[p]].paddr[31:LINE_LO] == fill_line", "1'b1"),
 ('dcresp-ld.gen-not-checked', 'lsu_dc_resp_ld.sv', 'wd_gen_q[widx[i]] == rsp_req_id[i][RIW+GENW-1:RIW]', "1'b1"),
 ('dcresp-ld.route-id-accepted', 'lsu_dc_resp_ld.sv', '!rsp_req_id[i][31]', "1'b1"),
 ('dcresp-ld.conflict-waits', 'lsu_dc_resp_ld.sv', "rsp_replay[i][1] ? REPLAY_WAIT : '0", "(rsp_replay[i] != '0) ? REPLAY_WAIT : '0"),
 ('dcresp-ld.duplicate-resp-applies', 'lsu_dc_resp_ld.sv', "if (eff[j] && lidx[j] == lidx[i]) eff[i] = 1'b0;", ""),
 ('dcresp-ld.fin-ignores-room', 'lsu_dc_resp_ld.sv', "finish_c.count + rank_fin[p] < RCW'(LQ)".replace("finish_c.count","fin_count_c"), "1'b1"),
 ('dcresp-st.wake-full-limit-plus1', 'lsu_dc_resp_st.sv', "rank_full[q] < RCW'(NST)", "rank_full[q] < RCW'(NST + 1)"),
 ('dcresp-st.wake-beyond-committed', 'lsu_dc_resp_st.sv', "assign in_cc[e]     = cc_count > RCW'(e);", "assign in_cc[e]     = 1'b1;"),
 ('dcresp-st.high-id-bits-ignored', 'lsu_dc_resp_st.sv', "rsp_req_id[i][31:SQW] == '0", "1'b1"),
 ('wbstq.sc-pass-ignores-addr', 'lsu_wb_stq.sv', "assign sc_pass_p[p]   = lrsc_valid_q && lrsc_addr_q == f_p[p].paddr;", "assign sc_pass_p[p]   = lrsc_valid_q;"),
 ('wbstq.sc-limit-ignored', 'lsu_wb_stq.sv', "rank_sc[p]  < RCW'(NLD)", "1'b1"),
 ('wbstq.sta-limit-ignored', 'lsu_wb_stq.sv', "rank_sta[p] < RCW'(NST)", "1'b1"),
 ('wbstq.sc-fault-keeps-reservation', 'lsu_wb_stq.sv', "assign sc_clear = |(acc_sc & ~pf_p);", "assign sc_clear = |acc_sc;"),
 ('wbldq.ignores-sc-ports', 'lsu_wb_ldq.sv', "rank[p] + n_sc < RCW'(NLD)", "rank[p] < RCW'(NLD)"),
 ('wbldq.fault-lr-arms', 'lsu_wb_ldq.sv', "f_p[p].lrsc && !f_p[p].pf", "f_p[p].lrsc"),
 ('wbldq.lr-first-wins', 'lsu_wb_ldq.sv', 'lrsc_addr_o = f_p[p].paddr;', 'lrsc_addr_o = (lrsc_addr_o == lrsc_addr_i) ? f_p[p].paddr : lrsc_addr_o;'),
 ('wbldq.dest-en-always', 'lsu_wb_ldq.sv', "wb_dest_en[k]   = f_p[p].dest != '0;", "wb_dest_en[k]   = 1'b1;"),
 ('exest.rob-flag-ignored', 'lsu_exe_in_st.sv', 'fld_q[sdu_stq_idx[p]].rob_flag == sdu_rob_flag[p]', "1'b1"),
 ('exest.std-ready-ignores-paddr', 'lsu_exe_in_st.sv', 'fld_q[sdu_stq_idx[p]].paddr_valid', "1'b1"),
 ('exest.sc-detect', 'lsu_exe_in_st.sv', "sta_amo_op[p] == AMO_SC", "1'b1"),
 ('exest.sta-rob-idx-ignored', 'lsu_exe_in_st.sv', 'fld_q[sta_stq_idx[p]].rob_idx == sta_rob_idx[p]', "1'b1"),
 ('exeld.rob-flag-inverted', 'lsu_exe_in_ld.sv', 'fld_q[req_ldq_idx[p]].rob_flag == req_rob_flag[p]', 'fld_q[req_ldq_idx[p]].rob_flag != req_rob_flag[p]'),
 ('exeld.lr-detect', 'lsu_exe_in_ld.sv', "req_amo_op[p] == AMO_LR", "1'b1"),
 ('tlbresp-ld.stlf-limit-ignored', 'lsu_tlb_resp_ld.sv', "rank_stlf[p] < RCW'(NLD)", "1'b1"),
 ('tlbresp-ld.stlf-room-ignored', 'lsu_tlb_resp_ld.sv', "stlf_count + rank_stlf[p] < RCW'(LQ)", "1'b1"),
 ('tlbresp-ld.fin-limit-ignored', 'lsu_tlb_resp_ld.sv', "rank_fin[p]  < RCW'(NLD)", "1'b1"),
 ('tlbresp-ld.stale-slot-not-killed', 'lsu_tlb_resp_ld.sv', "assign kill_slot_port[i] = slot_ok[i] && ld_st_agu[rsp_entry_idx[i]] != LD_WAIT_TLB;", "assign kill_slot_port[i] = 1'b0;"),
 ('tlbresp-ld.retry-ignored', 'lsu_tlb_resp_ld.sv', "assign is_retry[p]  = valid_w[p] && ld_st_tlb[idx_w[p]] == LD_WAIT_TLB_RETRY;", "assign is_retry[p]  = 1'b0;"),
 ('tlbresp-ld.pf-keeps-reservation', 'lsu_tlb_resp_ld.sv', "assign lrsc_clear = |(act & pf_port);", "assign lrsc_clear = 1'b0;"),
 ('tlbresp-st.pf-keeps-reservation', 'lsu_tlb_resp_st.sv', "assign lrsc_clear = |(act & pf_port);", "assign lrsc_clear = 1'b0;"),
 ('tlbresp-st.state-not-checked', 'lsu_tlb_resp_st.sv', 'st_exe[rsp_entry_idx[i]] == ST_WAIT_TLB', "1'b1"),
 ('tlbresp-st.wait-data-stays-queued', 'lsu_tlb_resp_st.sv', "valid_w & ~(is_done | is_data)", "valid_w & ~is_done"),
 ('tlbsel.picks-all-states', 'lsu_tlb_sel.sv', "assign cand[p] = valid_w[p] && wait_tlb[idx_w[p]];", "assign cand[p] = valid_w[p];"),
 ('stlf.snapshot-inclusive', 'lsu_stlf_match.sv', "{1'b0, RIW'(RIW'(s) - stq_head)} < age_dist", "{1'b0, RIW'(RIW'(s) - stq_head)} <= age_dist"),
 ('stlf.oldest-store-decides', 'lsu_stlf_match.sv', "assign rev_pos[j] = decider_pos[SQ-1-j];", "assign rev_pos[j] = decider_pos[j];"),
 ('stlf.cancelled-store-decides', 'lsu_stlf_match.sv', '!st_fld[s].suppress', "1'b1"),
 ('stlf.unknown-addr-forwards', 'lsu_stlf_match.sv', "assign retry_slot[s] = is_alloc || !st_fld[s].paddr_valid || cls == 2'd2 || !covers_ok;", "assign retry_slot[s] = is_alloc || cls == 2'd2 || !covers_ok;"),
 ('stlf.partial-forwards', 'lsu_stlf_match.sv', "cls == 2'd2", "1'b0"),
 ('stlf.sc-undecided-forwards', 'lsu_stlf_match.sv', "!(st_fld[s].lrsc && !st_fld[s].sc_pass) && st_fld[s].data_valid", "st_fld[s].data_valid"),
 ('stlf.no-data-forwards', 'lsu_stlf_match.sv', 'st_fld[s].data_valid', "1'b1"),
 ('stlf.fwd-offset-ignored', 'lsu_stlf_match.sv', "extract_data(sel_data, 2'(ld_paddr - sel_paddr), ld_func3)", "extract_data(sel_data, 2'd0, ld_func3)"),
 ('stlf.mmio-oldest-ignored', 'lsu_stlf.sv', "older_cnt == '0 && oldest", "older_cnt == '0"),
 ('stlf.mmio-older-stores-ignored', 'lsu_stlf.sv', "older_cnt == '0 && oldest", 'oldest'),
 ('stlf.head-incomplete-ignored', 'lsu_stlf.sv', 'rb_hi_valid ? rb_hi_rob_idx == ld_fld[idx_w[p]].rob_idx\n                                        : rb_head_valid && rb_head_rob_idx == ld_fld[idx_w[p]].rob_idx', 'rb_head_valid && rb_head_rob_idx == ld_fld[idx_w[p]].rob_idx'),
 ('stlf.two-mmio-loads-same-cycle', 'lsu_stlf_chain.sv', "mm_go   = mm && mmio_go[p] && !unc[p];", "mm_go   = mm && mmio_go[p];"),
 ('stlf.wdc-room-ignored', 'lsu_stlf_chain.sv', "ok_dc   = wd_count + nwd[p] < RCW'(LQ);", "ok_dc   = 1'b1;"),
 ('stlf.fin-room-ignored', 'lsu_stlf_chain.sv', "ok_fin  = fin_count + nfin[p] < RCW'(LQ);", "ok_fin  = 1'b1;"),
 ('stlf.scan-does-not-stop', 'lsu_stlf_chain.sv', "alive[p+1] = alive[p] && !(active && valid[p] && !pop[p]);", "alive[p+1] = alive[p];"),
 ('stlf.retry-room-ignored', 'lsu_stlf.sv', "stlf_pk_count + rank_retry[p] < RCW'(LQ)", "1'b1"),
 ('alloc.stq-capacity-short', 'lsu_alloc.sv', "stq_count + rank[i] < RCW'(SQ)", "stq_count + rank[i] < RCW'(SQ - 1)"),
 ('alloc.stq-slot-ignores-rank', 'lsu_alloc.sv', "stq_head + RIW'(stq_count) + RIW'(rank[i]) == RIW'(e)", "stq_head + RIW'(stq_count) == RIW'(e)"),
 ('flush.ring-ld-no-mispred-kill', 'lsu_flush_ring_ld.sv', "op.kill_slot = mispred ? dead : '0;", "op.kill_slot = '0;"),
 ('flush.ring-st-no-mispred-kill', 'lsu_flush_ring_st.sv', "op.kill_slot = mispred ? dead : '0;", "op.kill_slot = '0;"),
 ('flush.ring-ld-no-flush', 'lsu_flush_ring_ld.sv', "op.flush     = flush;", "op.flush     = 1'b0;"),
 ('ptr.mispred-keeps-one-more', 'lsu_stq_ptr.sv', "if (hit_first[j]) count_m = RCW'(j);", "if (hit_first[j]) count_m = RCW'(j) + RCW'(1);"),
 ('ptr.flush-drops-committed', 'lsu_stq_ptr.sv', "assign count_flushed  = flush ? keep_committed : count_al;", "assign count_flushed  = flush ? '0 : count_al;"),
 ('ptr.retire-window-unlimited', 'lsu_stq_ptr.sv', "assign window    = committed > RCW'(WIN) ? RCW'(WIN) : committed;", "assign window    = committed;"),
 ('ptr.retire-ignores-committed', 'lsu_stq_ptr.sv', "assign committed = ccount_fl > count_fl ? count_fl : ccount_fl;", "assign committed = count_fl;"),
 ('ptr.ccount-not-truncated', 'lsu_stq_ptr.sv', "(mispred && ccount_flushed > count_m) ? count_m : ccount_flushed", "ccount_flushed"),
 ('ptr.clear-window-all', 'lsu_stq_ptr.sv', "assign clr_win[s]  = stq_alive(RIW'(s), head_q, count_q);", "assign clr_win[s]  = 1'b1;"),
 ('unc.flush-keeps-any-store', 'lsu_unc.sv', 'st_st_pre_flush[idx2] == ST_WAIT_MMIO_RESP', "1'b1"),
 ('unc.flush-keeps-load', 'lsu_unc.sv', '!is_load2', "1'b1"),
 ('unc.mispred-ld-kill-ignored', 'lsu_unc.sv', 'ld_empty[idx2]', "1'b0"),
 ('unc.mispred-st-kill-ignored', 'lsu_unc.sv', '!stq_alive(idx2, stq_head, count_final)', "1'b0"),
 ('lrsc.pf-keeps', 'lsu_lrsc.sv', "assign alive = valid_i && !pf_clear && !(mispred && (br_i & dec_br_mask) != '0);", "assign alive = valid_i && !(mispred && (br_i & dec_br_mask) != '0);"),
 ('lrsc.mispred-keeps', 'lsu_lrsc.sv', "!(mispred && (br_i & dec_br_mask) != '0)", "1'b1"),
 ('lrsc.br-not-cleared', 'lsu_lrsc.sv', "br_q   <= alive ? br_i & ~clear_mask : br_i;", "br_q   <= br_i;"),
 ('dcreq-ld.countdown-late', 'lsu_dc_req_ld.sv', "issue[p]  = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] < RWW'(2);", "issue[p]  = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] < RWW'(1);"),
 ('dcreq-ld.issue-limit-ignored', 'lsu_dc_req_ld.sv', "issue[p]  = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] < RWW'(2);", "issue[p]  = cand[p] && w_p[p] < RWW'(2);"),
 ('dcreq-ld.gen-per-port-ignored', 'lsu_dc_req_ld.sv', "req_id[k]    = {req_gen_q + GENW'(k), slot_w[p]};", "req_id[k]    = {req_gen_q, slot_w[p]};"),
 ('dcreq-ld.dec-limit-ignored', 'lsu_dc_req_ld.sv', "dec[p]    = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] != '0;", "dec[p]    = cand[p] && w_p[p] != '0;"),
 ('dcreq-st.suppressed-not-unblocking', 'lsu_dc_req_st.sv', "assign done_after[i] = done_w[i] || sup_done[i];", "assign done_after[i] = done_w[i];"),
 ('dcreq-st.reissue-same-cycle', 'lsu_dc_req_st.sv', 'assign cand[i]       = in_w[i] && committed_w[i] && !wdr_w[i];', 'assign cand[i]       = in_w[i] && committed_w[i] && (!wdr_w[i] || mmio_w[i]);'),
 ('dcreq-st.mmio-any-position', 'lsu_dc_req_st.sv', 'mmio_w[i] && i == 0 && !unc_valid', 'mmio_w[i] && !unc_valid'),
 ('dcreq-st.mmio-ignores-busy-unit', 'lsu_dc_req_st.sv', 'mmio_w[i] && i == 0 && !unc_valid', 'mmio_w[i] && i == 0'),
 ('dcreq-st.no-same-addr-block', 'lsu_dc_req_st.sv', "assign blocked[i]    = |live_conf[i];", "assign blocked[i]    = 1'b0;"),
 ('dcreq-st.issue-limit-ignored', 'lsu_dc_req_st.sv', "assign visited       = n_iss[i] < RCW'(NST);", "assign visited       = 1'b1;"),
 ('dcreq-st.window-beyond-committed', 'lsu_dc_req_st.sv', "assign in_w[q]        = stq_ccount > RCW'(q);", "assign in_w[q]        = 1'b1;"),
 ('wdslot.clear-ignored', 'lsu_wd_slot.sv', "assign wait_wk[s] = clr[s] ? '0 : w_set;", "assign wait_wk[s] = w_set;"),
 ('wdslot.gen-not-counted', 'lsu_wd_slot.sv', "req_gen_q + GENW'(n_iss)", "req_gen_q"),
 # --- entries
 ('ldq.clear-mask-not-applied', 'lsu_ldq_ent.sv', "assign brm_wd    = (st_cur != LD_EMPTY) ? brm_al & ~clear_mask : brm_al;", "assign brm_wd    = brm_al;"),
 ('ldq.clear-mask-hits-new-entry', 'lsu_ldq_ent.sv', '(st_cur != LD_EMPTY)', "1'b1"),
 ('ldq.mispred-uses-old-brmask', 'lsu_ldq_ent.sv', "(brm_al & dec_br_mask) != '0", "(fld_cur.br_mask & dec_br_mask) != '0"),
 ('ldq.mispred-kills-empty-alloc', 'lsu_ldq_ent.sv', 'st_al != LD_EMPTY', "1'b1"),
 ('ldq.replay-not-reset-at-alloc', 'lsu_ldq_ent.sv', "assign replay_wd = al_ev.go ? REPLAY_HIT : dc_ev.rp;", "assign replay_wd = al_ev.go ? fld_cur.replay : dc_ev.rp;"),
 ('ldq.pf-not-reset-at-alloc', 'lsu_ldq_ent.sv', "assign pf_clr    = al_ev.go;", "assign pf_clr    = 1'b0;"),
 ('ldq.tlb-miss-hit-order', 'lsu_ldq_ent.sv', 'st_tlb = LD_WAIT_TLB_RETRY;', 'st_tlb = LD_WAIT_TLB;'),
 ('ldq.mmio-flag-from-vaddr', 'lsu_ldq_ent.sv', "fld_reg_q.mmio  <= is_mmio_addr(tr_ev.paddr);", "fld_reg_q.mmio  <= 1'b0;"),
 ('ldq.replay-hit-state', 'lsu_ldq_ent.sv', "st_rsp = dc_ev.hit ? LD_READY_TO_WB : LD_READY_TO_ISSUE;", "st_rsp = LD_READY_TO_WB;"),
 ('ldq.wait-finish-no-pagefault-state', 'lsu_ldq_ent.sv', "if (tw_ev.fin)   st_win = LD_PAGE_FAULT;", "if (tw_ev.fin)   st_win = LD_READY_TO_WB;"),
 ('stq.flush-commit-not-cancelled', 'lsu_stq_ent.sv', "assign to_done = flush || (fld_cur.lrsc && !fld_cur.sc_pass);", "assign to_done = (fld_cur.lrsc && !fld_cur.sc_pass);"),
 ('stq.failed-sc-commits', 'lsu_stq_ent.sv', 'to_done ? ST_DONE : ST_COMMITTED', 'flush ? ST_DONE : ST_COMMITTED'),
 ('stq.sc-verdict-not-suppress', 'lsu_stq_ent.sv', "assign supp_wd = al_ev.go ? 1'b0 : (wb_ev.sc_upd ? !wb_ev.pass : 1'b1);", "assign supp_wd = al_ev.go ? 1'b0 : 1'b1;"),
 ('stq.sta-keeps-paddr-valid', 'lsu_stq_ent.sv', "assign pv_we   = ex_ev.sta_go || tr_hit || al_ev.go;", "assign pv_we   = tr_hit || al_ev.go;"),
 ('stq.tlb-hit-ignores-data-valid', 'lsu_stq_ent.sv', 'st_tlb = dv_g ? ST_WAIT_DONE : ST_WAIT_DATA;', 'st_tlb = ST_WAIT_DONE;'),
 ('stq.tlb-hit-uses-old-data-valid', 'lsu_stq_ent.sv', "assign dv_g    = fld_cur.data_valid || ex_ev.std_go;", "assign dv_g    = fld_cur.data_valid;"),
 ('stq.sta-overrides-std-ready', 'lsu_stq_ent.sv', "st_exe = ex_ev.sta_go ? ST_WAIT_TLB : (ex_ev.std_rdy ? ST_READY : st_wb);", "st_exe = ex_ev.std_rdy ? ST_READY : (ex_ev.sta_go ? ST_WAIT_TLB : st_wb);"),
 ('stq.replay-wait-all-types', 'lsu_stq_ent.sv', "(!dc_ev.hit && dc_ev.rp[1]) ? REPLAY_WAIT : '0", "(!dc_ev.hit) ? REPLAY_WAIT : '0"),
 ('stq.pagefault-state', 'lsu_stq_ent.sv', "st_win = pf_i1 ? ST_PAGE_FAULT : ST_READY;", "st_win = ST_READY;"),
 ('stq.mmio-flag-not-reset', 'lsu_stq_ent.sv', "assign mmio_wd = !al_ev.go && is_mmio_addr(tr_ev.paddr);", "assign mmio_wd = is_mmio_addr(tr_ev.paddr);"),
 ('stq.clear-mask-not-applied', 'lsu_stq_ent.sv', "assign brm_wd  = clr_win ? br_al & ~clear_mask : br_al;", "assign brm_wd  = br_al;"),
 ('stq.sup-wait-not-cleared', 'lsu_stq_ent.sv', "assign wait_wd = is_ev.sup ? '0 : (is_ev.dec ? w_n - RWW'(1) : w_n);", "assign wait_wd = is_ev.dec ? w_n - RWW'(1) : w_n;"),
]

DECL = 'import "DPI-C" pure function int ttg_mut_sel();\n'
MDECL = '  import "DPI-C" pure function int ttg_mut_sel();\n  int unsigned mut_sel;\n  initial mut_sel = ttg_mut_sel();\n'
STUB = '#include <cstdlib>\nextern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n'
SCREEN = [('smc-div', 'tests', 100000), ('memory-stress', 'tests', 100000), ('atomic-boundary', 'tests', 100000),
          ('vm_pagefault_test', 'vm', 100000), ('dhrystone', 'big', 150000)]


def prog(n, kind):
    if kind == 'big': return f'/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/{n}.bin'
    import glob
    h = glob.glob(f'{G}/{kind}/*/{n}.bin')
    return h[0] if h else None


def run_one(refsim, dylib, p, cycles, mut):
    env = dict(os.environ, TTG_MUT=str(mut), TTG_REC=dylib, TTG_MULTI='1', TTG_REC_N=str(cycles))
    r = subprocess.run([f'{refsim}/build/simulator', p], cwd=refsim, env=env, capture_output=True, text=True, errors='replace')
    out = r.stdout + r.stderr
    m = re.search(r'MISMATCH[^\n]*', out)
    if m or 'LOCKSTEP FAIL' in out:
        return True, (m.group(0)[:100] if m else 'LOCKSTEP FAIL')
    if 'LOCKSTEP PASS' in out:
        return False, ''
    return True, f'abort exit {r.returncode}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jobs', type=int, default=2)
    ap.add_argument('--only', default='')
    ap.add_argument('--extra', action='store_true', help='survivors also run on up to 12 short programs x 150k cycles')
    a = ap.parse_args()
    refsim = os.environ.get('REFSIM', os.path.join(ROOT, 'refsim_tap'))
    T = os.path.join(ROOT, 'build/mutlsu')
    shutil.rmtree(T, ignore_errors=True)
    for d in ('rtl', 'spec', 'harness', 'scripts'):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(T, d))
    texts, ids, bad = {}, {}, []
    for name, f, old, new in M:
        s = texts.setdefault(f, open(os.path.join(T, D + f)).read())
        if old not in s:
            bad.append(name); continue
        k = len(ids) + 1
        sel = '(ttg_mut_sel() == %d)' % k if f.endswith('_pkg.sv') else f'(mut_sel == {k})'
        texts[f] = s.replace(old, guard(old, new, sel), 1)
        ids[k] = name
    if bad:
        print('PATTERN MISSING:', bad); sys.exit(1)
    for f, s in texts.items():
        if f.endswith('_pkg.sv'):
            s = s.replace('package lsu_pkg;\n', 'package lsu_pkg;\n  import "DPI-C" pure function int ttg_mut_sel();\n', 1)
        else:
            s = re.sub(r'(\n\);\n)', lambda m: m.group(1) + MDECL, s, count=1)
            s = DECL + s if False else s
        open(os.path.join(T, D + f), 'w').write(s)
    open(os.path.join(T, 'ttg_mut_stub.cpp'), 'w').write(STUB)
    env = dict(os.environ, BUILD_ONLY='1', VFLAGS='-Wno-fatal', EXTRA_CPP=os.path.join(T, 'ttg_mut_stub.cpp'), REFSIM=refsim)
    r = subprocess.run(f'bash {T}/scripts/lockstep.sh lsu x', shell=True, env=env, capture_output=True, text=True)
    dylib = os.path.join(T, 'build/lock_lsu/lock_lsu.dylib')
    if not os.path.exists(dylib):
        print('BUILD FAILED', (r.stdout + r.stderr)[-1500:]); sys.exit(1)
    progs = [(prog(n, k), c) for n, k, c in SCREEN if prog(n, k)]
    print(f'built: {len(ids)} mutants in one build; screening: {[os.path.basename(p) for p, _ in progs]}', flush=True)
    f0, i0 = run_one(refsim, dylib, progs[0][0], 20000, 0)
    print('baseline (TTG_MUT=0):', 'FAIL ' + i0 if f0 else 'PASS', flush=True)
    sel = [int(x) for x in a.only.split(',')] if a.only else list(ids)
    ex = []
    if a.extra:
        lst = os.path.join(ROOT, 'build/lockstep_multi.progs')
        allp = [l.strip() for l in open(lst)]
        ex = [(p, 150000) for p in allp if not any(x in p for x in ('dhrystone', 'coremark', 'memory-stress'))][:12]

    def one(k):
        for p, c in progs + ex:
            fail, info = run_one(refsim, dylib, p, c, k)
            if fail:
                return k, 'KILLED', f'{os.path.basename(p)}: {info}'
        return k, 'SURVIVED', ''
    res = os.path.join(ROOT, 'build/mut_lsu.txt')
    open(res, 'w').close()
    with cf.ThreadPoolExecutor(a.jobs) as pool:
        for fu in cf.as_completed([pool.submit(one, k) for k in sel]):
            k, st, info = fu.result()
            line = f'{st:9s} {k:3d} {ids[k]}  {info}'
            print(line, flush=True); open(res, 'a').write(line + '\n')


STMT = re.compile(r"^(if\b|return\b|[A-Za-z_][\w.]*(\[[^\]]*\])*\s*(<=|=)[^=])")


def guard(old, new, sel):
    """assign-form: same LHS; statement (if / return / x = ..; / x <= ..;): if (sel) begin NEW end else begin OLD end;
    otherwise old/new are complete expressions: ((sel) ? (new) : (old))"""
    m1 = re.match(r'^(assign\s+[^=]+?=\s*)(.*?);$', old.strip(), re.S)
    m2 = re.match(r'^(assign\s+[^=]+?=\s*)(.*?);$', new.strip(), re.S)
    if m1 and m2 and m1.group(1).strip() == m2.group(1).strip():
        return f'{m1.group(1)}{sel} ? ({m2.group(2)}) : ({m1.group(2)});'
    if old.rstrip().endswith(';') and STMT.match(old.strip()):
        return f'if {sel} begin {new} end else begin {old} end'
    return f'(({sel}) ? ({new}) : ({old}))'


if __name__ == '__main__':
    main()
