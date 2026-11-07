# PreIduQueue: FTQ + InstructionBuffer between front end and Idu. Ref: back-end/PreIduQueue.cpp, InstructionBuffer.cpp, include/FTQ.h
# Boundary = BackTop PRE(comb_begin/comb_accept_front/comb_ftq_lookup_rob/comb_ftq_lookup_prf/comb_commit_info/comb_fire/seq); trace point = end of comb, before seq.
# Not translated: perf/dbg, InstructionBuffer pc (only Idu dbg.pc reads it), FTQ entry_valid / ftq_valid[] (no consumer), mid_pred (never read),
# front2pre.front_stall (unread), predict_next_fetch_address[1..] (only [0] read), ftq_rob_pc_resp pred_taken/next_pc (Rob reads only valid/pc).
module pre_idu_queue

# ---- inputs: front end -> PreIduQueue (bt.in = FrontPreIO) ----
in  front2pre_valid 1 [16] @ bt.in.valid[i0]
in  front2pre_inst 32 [16] @ bt.in.inst[i0]
in  front2pre_pc 32 [16] @ bt.in.pc[i0]
in  front2pre_page_fault_inst 1 [16] @ bt.in.page_fault_inst[i0]
in  front2pre_predict_dir 1 [16] @ bt.in.predict_dir[i0]
in  front2pre_alt_pred 1 [16] @ bt.in.alt_pred[i0]
in  front2pre_altpcpn 3 [16] @ bt.in.altpcpn[i0]
in  front2pre_pcpn 3 [16] @ bt.in.pcpn[i0]
in  front2pre_predict_next_fetch_address 32 @ bt.in.predict_next_fetch_address[0]
in  front2pre_tage_idx 10 [16][4] @ bt.in.tage_idx[i0][i1]
in  front2pre_tage_tag 8 [16][4] @ bt.in.tage_tag[i0][i1]

# ---- inputs: Idu consume / branch latch, Rob broadcast + commit, FTQ read requests ----
in  idu_consume_fire 1 [8] @ bt.idu_consume.fire[i0]
in  idu_br_latch_mispred 1 @ bt.idu->br_latch.mispred
in  idu_br_latch_ftq_idx 6 @ bt.idu->br_latch.ftq_idx
in  idu_br_latch_br_pc 32 @ bt.idu->br_latch.br_pc
in  front2pre_bpu_ck 148 @ bt.in.bpu_ck
in  front2pre_slot_kind 24 @ bt.in.slot_kind
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  rob_commit_commit_entry_valid 1 [8] @ bt.rob_commit.commit_entry[i0].valid
in  rob_commit_commit_entry_uop_ftq_idx 6 [8] @ bt.rob_commit.commit_entry[i0].uop.ftq_idx
in  rob_commit_commit_entry_uop_ftq_offset 4 [8] @ bt.rob_commit.commit_entry[i0].uop.ftq_offset
in  rob_commit_commit_entry_uop_ftq_is_last 1 [8] @ bt.rob_commit.commit_entry[i0].uop.ftq_is_last
in  ftq_prf_pc_req_req_valid 1 [10] @ bt.ftq_prf_pc_req.req[i0].valid
in  ftq_prf_pc_req_req_ftq_idx 6 [10] @ bt.ftq_prf_pc_req.req[i0].ftq_idx
in  ftq_prf_pc_req_req_ftq_offset 4 [10] @ bt.ftq_prf_pc_req.req[i0].ftq_offset
in  ftq_rob_pc_req_req_valid 1 [1] @ bt.ftq_rob_pc_req.req[i0].valid
in  ftq_rob_pc_req_req_ftq_idx 6 [1] @ bt.ftq_rob_pc_req.req[i0].ftq_idx
in  ftq_rob_pc_req_req_ftq_offset 4 [1] @ bt.ftq_rob_pc_req.req[i0].ftq_offset

# ---- outputs: pre2front handshake (fire is not gated by lane validity beyond valid[i]) ----
out pre2front_ready 1 @ bt.pre2front.ready
out out_rf_ck 140 @ bt.rf.ck
out out_rf_epoch 8 @ bt.rf.epoch
out out_rf_type 3 @ bt.rf.type
out pre2front_fire 1 [16] @ bt.pre2front.fire[i0]

# ---- outputs: issue group to Idu (payload only meaningful when the slot is valid) ----
out pre_issue_entries_valid 1 [8] @ bt.pre_issue.entries[i0].valid
out pre_issue_entries_inst 32 [8] when pre_issue_entries_valid @ bt.pre_issue.entries[i0].inst
out pre_issue_entries_page_fault_inst 1 [8] when pre_issue_entries_valid @ bt.pre_issue.entries[i0].page_fault_inst
out pre_issue_entries_ftq_idx 6 [8] when pre_issue_entries_valid @ bt.pre_issue.entries[i0].ftq_idx
out pre_issue_entries_ftq_offset 4 [8] when pre_issue_entries_valid @ bt.pre_issue.entries[i0].ftq_offset
out pre_issue_entries_ftq_is_last 1 [8] when pre_issue_entries_valid @ bt.pre_issue.entries[i0].ftq_is_last

# ---- outputs: FTQ pc lookup for Prf (10 ports) and Rob (1 port); resp.valid is the req valid pass-through ----
out ftq_prf_pc_resp_resp_valid 1 [10] @ bt.ftq_prf_pc_resp.resp[i0].valid
out ftq_prf_pc_resp_resp_pc 32 [10] when ftq_prf_pc_resp_resp_valid @ bt.ftq_prf_pc_resp.resp[i0].pc
out ftq_prf_pc_resp_resp_pred_taken 1 [10] when ftq_prf_pc_resp_resp_valid @ bt.ftq_prf_pc_resp.resp[i0].pred_taken
out ftq_prf_pc_resp_resp_next_pc 32 [10] when ftq_prf_pc_resp_resp_valid @ bt.ftq_prf_pc_resp.resp[i0].next_pc
out ftq_rob_pc_resp_resp_valid 1 [1] @ bt.ftq_rob_pc_resp.resp[i0].valid
out ftq_rob_pc_resp_resp_pc 32 [1] when ftq_rob_pc_resp_resp_valid @ bt.ftq_rob_pc_resp.resp[i0].pc

out ftq_commit_info_resp_valid_t 1 [8][4] @ bt.rob_commit.commit_entry[i0].valid
# ---- outputs: commit-time FTQ info (spec-only qualifier ftq_commit_info_resp_valid == rob commit valid; C++ zeroes resp when !valid) ----
out ftq_commit_info_resp_valid 1 [8] @ bt.rob_commit.commit_entry[i0].valid
out ftq_commit_info_resp_pc 32 [8] when ftq_commit_info_resp_valid @ bt.ftq_commit_info.resp[i0].pc
out ftq_commit_info_resp_pred_taken 1 [8] when ftq_commit_info_resp_valid @ bt.ftq_commit_info.resp[i0].pred_taken
out ftq_commit_info_resp_alt_pred 1 [8] when ftq_commit_info_resp_valid @ bt.ftq_commit_info.resp[i0].alt_pred
out ftq_commit_info_resp_altpcpn 3 [8] when ftq_commit_info_resp_valid @ bt.ftq_commit_info.resp[i0].altpcpn
out ftq_commit_info_resp_pcpn 3 [8] when ftq_commit_info_resp_valid @ bt.ftq_commit_info.resp[i0].pcpn
out ftq_commit_info_resp_tage_idx 10 [8][4] when ftq_commit_info_resp_valid_t @ bt.ftq_commit_info.resp[i0].tage_idx[i1]
out ftq_commit_info_resp_tage_tag 8 [8][4] when ftq_commit_info_resp_valid_t @ bt.ftq_commit_info.resp[i0].tage_tag[i1]
