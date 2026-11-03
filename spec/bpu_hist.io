# BPU history + RAS: Spec/Arch GHR + folded histories (what feeds the TAGE index) and the return address stack.
# Inputs: the commit lanes (BPU InputPayload) and the fetch-group lane info the BPU computed this cycle
# (do_pred_on_this_pc, do_pred_for_this_pc, final_pred_dir, going_to_do_pred) plus the lane's predicted branch type
# (the type predictor's answer, read from the BTB request of the lane's bank as in bpu_type.io).
# Outputs: fh = Spec folded history at the start of the cycle (== tage_in[b].fh_in); RAS top as the predictor sees it
# (Arch copy in a refetch cycle, Spec copy otherwise; BPU::rd.ras_top_snapshot).  Spec/Arch GHR themselves are internal;
# they become visible through later fh values.
module bpu_hist
in  refetch    1  @ cpu.front.update_req_->bpu_seq_txn.inp.refetch
in  pred_en    1  @ cpu.front.update_req_->bpu_seq_txn.req.going_to_do_pred
in  lane_valid 1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.do_pred_on_this_pc[i0]
in  lane_pc    32 [8] @ cpu.front.update_req_->bpu_seq_txn.req.do_pred_for_this_pc[i0]
in  lane_type  3  [8] @ (cpu.front.update_req_->bpu_seq_txn.req.this_pc_bank_sel[i0] < 8 ? cpu.front.update_req_->bpu_seq_txn.req.btb_in[cpu.front.update_req_->bpu_seq_txn.req.this_pc_bank_sel[i0] & 7].pred_type_in : 0)
in  lane_taken 1  [8] @ cpu.front.update_req_->bpu_seq_txn.req.final_pred_dir[i0]
in  upd_valid  1  [8] @ cpu.front.update_req_->bpu_seq_txn.inp.in_upd_valid[i0]
in  upd_pc     32 [8] @ cpu.front.update_req_->bpu_seq_txn.inp.in_update_base_pc[i0]
in  actual_dir 1  [8] @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_dir[i0]
in  br_type    3  [8] @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_br_type[i0]
in  pred_dir   1  [8] @ cpu.front.update_req_->bpu_seq_txn.inp.in_pred_dir[i0]
out fh         11 [3][4] @ cpu.front.update_req_->bpu_seq_txn.req.tage_in[0].fh_in[i0][i1]
out ras_has    1  @ ([&]() -> uint64_t { static BPU_TOP::ReadData rd; auto &in = cpu.front.update_req_->bpu_seq_txn.inp; g_bpu_top->bpu_seq_read(in, rd); return (in.refetch ? rd.Arch_ras_count_snapshot : rd.Spec_ras_count_snapshot) > 0; })()
out ras_top    32 when ras_has @ ([&]() -> uint64_t { static BPU_TOP::ReadData rd; auto &in = cpu.front.update_req_->bpu_seq_txn.inp; g_bpu_top->bpu_seq_read(in, rd); return in.refetch ? (rd.Arch_ras_count_snapshot > 0 ? rd.Arch_ras_stack_snapshot[rd.Arch_ras_count_snapshot - 1] : 0) : (rd.Spec_ras_count_snapshot > 0 ? rd.Spec_ras_stack_snapshot[rd.Spec_ras_count_snapshot - 1] : 0); })()
