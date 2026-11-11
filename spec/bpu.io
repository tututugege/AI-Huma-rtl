# BPU top (BPU_TOP::InputPayload -> OutputPayload), default configuration.  See docs/modules/bpu.md.
# Inputs: bpu_seq_txn.inp (what front_top.cpp hands to bpu_comb_calc every cycle).  Not in the spec: in_altpcpn (stored in
# the update queue, never read), in_sc_* / in_loop_* (constant 0: SC-L and loop predictor are disabled).
# Outputs: TTG_FT.bpu_out (tap copy of the BPU's OutputPayload).  Not in the spec: out_sc_* / out_loop_* (constant 0),
# update_queue_full (constant 0 -> front.out.commit_stall == 0), two_ahead_* / mini_flush_* (2-ahead path is compiled out),
# out_pred_base_pc (== fetch_address, asserted in the C++).
# Relaxed (when): fetch_address only matters when icache_read_valid (fetch_addr FIFO write, front_top.cpp 1429);
# the PTAB payload only when PTAB_write_enable (front_ptab_write_comb is guarded by ptab_can_write).
module bpu
in  refetch           1  @ cpu.front.update_req_->bpu_seq_txn.inp.refetch
in  refetch_address   32 @ cpu.front.update_req_->bpu_seq_txn.inp.refetch_address
in  icache_read_ready 1  @ cpu.front.update_req_->bpu_seq_txn.inp.icache_read_ready
in  upd_valid  1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_upd_valid[i0]
in  base_pc    32 [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_update_base_pc[i0]
in  actual_dir 1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_dir[i0]
in  br_type    3  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_br_type[i0]
in  target     32 [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_targets[i0]
in  pred_dir   1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_pred_dir[i0]
in  alt_pred   1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_alt_pred[i0]
in  pcpn       3  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_pcpn[i0]
in  tags       8  [8][4] @ cpu.front.update_req_->bpu_seq_txn.inp.in_tage_tags[i0][i1]
in  idxs       10 [8][4] @ cpu.front.update_req_->bpu_seq_txn.inp.in_tage_idxs[i0][i1]
out icache_read_valid 1  @ TTG_FT.bpu_out.icache_read_valid
out fetch_address     32 when icache_read_valid @ TTG_FT.bpu_out.fetch_address
out ptab_write_enable 1  @ TTG_FT.bpu_out.PTAB_write_enable
out predict_next_fetch_address 32 when ptab_write_enable @ TTG_FT.bpu_out.predict_next_fetch_address
out out_pred_dir  1  [8]    when ptab_write_enable @ TTG_FT.bpu_out.pred_dir[i0]
out out_alt_pred  1  [8]    when ptab_write_enable @ TTG_FT.bpu_out.alt_pred[i0]
out out_pcpn      3  [8]    when ptab_write_enable @ TTG_FT.bpu_out.pcpn[i0]
out out_tage_tags 8  [8][4] when ptab_write_enable @ TTG_FT.bpu_out.tage_tags[i0][i1]
out out_tage_idxs 10 [8][4] when ptab_write_enable @ TTG_FT.bpu_out.tage_idxs[i0][i1]
