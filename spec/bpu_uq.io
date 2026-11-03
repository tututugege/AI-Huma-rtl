# BPU update queue (Q_DEPTH=2 per bank; behaves as a 1-entry register, see docs/analysis/bpu-boundary.md 3.6).
# Inputs: the commit lanes of BPU::InputPayload.  Dropped: altpcpn (stored, never read), sc_*/loop_* (constant 0).
# Outputs: the per-bank queue head as handed to the BTB (btb_in[b].upd_*) and TAGE (tage_in[b].*) of the same cycle.
# All outputs are zero when the bank's queue is empty; TAGE fields are zero unless the head is a conditional branch.
module bpu_uq
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
out q_valid    1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.going_to_do_upd[i0]
out q_pc       29 [8]    @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_pc
out q_target   32 [8]    @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_actual_addr
out q_br_type  3  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_br_type_in
out q_dir      1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_actual_dir
out tage_en    1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].update_en
out q_pred_dir 1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pred_in
out q_alt_pred 1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].alt_pred_in
out q_pcpn     3  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pcpn_in
out q_tags     8  [8][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].tage_tag_flat_in[i1]
out q_idxs     10 [8][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].tage_idx_flat_in[i1]
