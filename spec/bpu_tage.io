# BPU TAGE: 8 banks (one TAGE_TOP each).  Inputs = bpu_seq_txn.req.tage_in[b] (TAGE_TOP::InputPayload as built by the BPU).
# Dropped inputs: ghr_in/path_in (read only by the disabled SC-L), sc_*/loop_* (constant 0), altpcpn_in (stored, never read
# by tage_update_comb), the 32-bit bank pc (only bits [11:2] reach the index: (pc>>2)&1023 for the base table and hashes).
# fh_in is the speculative folded history and identical for all banks (read from bank 0).
# Outputs = req.tage_req[b].out_regs; all are zero when pred_req is 0 (memset in the C++), compared strictly.
module bpu_tage
in  fh          11 [3][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[0].fh_in[i0][i1]
in  pred_req    1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pred_req
in  pred_pc_idx 10 [8]    @ (cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pc_pred_in >> 2) & 0x3ff
in  update_en   1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].update_en
in  upd_pc_idx  10 [8]    @ (cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pc_update_in >> 2) & 0x3ff
in  real_dir    1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].real_dir
in  pred_in     1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pred_in
in  alt_pred_in 1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].alt_pred_in
in  pcpn_in     3  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].pcpn_in
in  tag_in      8  [8][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].tage_tag_flat_in[i1]
in  idx_in      10 [8][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[i0].tage_idx_flat_in[i1]
out pred_out     1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_req[i0].out_regs.pred_out
out alt_pred_out 1  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_req[i0].out_regs.alt_pred_out
out pcpn_out     3  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_req[i0].out_regs.pcpn_out
out altpcpn_out  3  [8]    @ cpu.front.update_req_->bpu_seq_txn.req.tage_req[i0].out_regs.altpcpn_out
out tag_out      8  [8][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_req[i0].out_regs.tage_tag_flat_out[i1]
out idx_out      10 [8][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_req[i0].out_regs.tage_idx_flat_out[i1]
