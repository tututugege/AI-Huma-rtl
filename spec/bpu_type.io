# BPU type predictor (TypePredictor.h): 8 banks x 512 sets x 2 ways, 8 prediction lanes + 8 update lanes per cycle.
# Inputs are exactly bpu_seq_txn.req.type_in (what BPU::bpu_post_read_req_comb hands to the sub-module).
# pred_type is not stored in the transaction as such; the BPU binds it into the BTB request of the lane's bank
# (bpu_submodule_bind_comb: btb_in[bank].pred_type_in = type_out.pred_type[i]), which is what we read back.
# Only meaningful for lanes with pred_valid (other lanes are forced to NONCTL by the C++ and ignored by the BPU).
# Update lanes use the commit inputs of the SAME cycle directly (no update queue) and read the pre-write table.
module bpu_type
in  pred_valid  1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.type_in.pred_valid[i0]
in  pred_pc     32 [8] @ cpu.front.update_req_->bpu_seq_txn.req.type_in.pred_pc[i0]
in  upd_valid   1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.type_in.upd_valid[i0]
in  upd_pc      32 [8] @ cpu.front.update_req_->bpu_seq_txn.req.type_in.upd_pc[i0]
in  upd_br_type 3  [8] @ cpu.front.update_req_->bpu_seq_txn.req.type_in.upd_br_type[i0]
out pred_type   3  [8] when pred_valid @ (cpu.front.update_req_->bpu_seq_txn.req.this_pc_bank_sel[i0] < 8 ? cpu.front.update_req_->bpu_seq_txn.req.btb_in[cpu.front.update_req_->bpu_seq_txn.req.this_pc_bank_sel[i0] & 7].pred_type_in : 0)
