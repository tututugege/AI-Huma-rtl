# BPU BTB: 8 banks (one BTB_TOP each).  Inputs = bpu_seq_txn.req.btb_in[b] (BTB_TOP::InputPayload as built by the BPU;
# pred_pc/upd_pc are the BANK pc = pc>>3, 29 bits).  Output = req.btb_req[b].out_regs.pred_target, valid when pred_req
# (btb_pred_out_valid == pred_req).  btb_update_done/busy are constants.
# pred_type_in is the type predictor's answer for the lane of this bank (BR_NONCTL when the bank has no lookup).
module bpu_btb
in  pred_req        1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].pred_req
in  pred_pc         29 [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].pred_pc
in  pred_type_in    3  [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].pred_type_in
in  upd_valid       1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_valid
in  upd_pc          29 [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_pc
in  upd_actual_addr 32 [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_actual_addr
in  upd_br_type_in  3  [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_br_type_in
in  upd_actual_dir  1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.btb_in[i0].upd_actual_dir
out pred_target     32 [8] when pred_req @ cpu.front.update_req_->bpu_seq_txn.req.btb_req[i0].out_regs.pred_target
