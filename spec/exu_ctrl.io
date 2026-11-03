# Exu control/arbitration (back-end/Exu/Exu.cpp class Exu without the functional units; analysis docs/analysis/exu-boundary.md E6).
# Boundary = BackTop wires prf2exe, dec_bcast, rob_bcast, lsu2exe, csr2exe -> exe2prf, exe2iss, exe2csr, exe2lsu, exu2id, exu2rob;
# plus the FU side: what the 28 FU instances (units[] in port order, docs/analysis/exu-boundary.md 1.1) hand back (fu_*) and are given (exu2fu_*).
#
# FU index groups (fu_idx of Exu::units): alu = {1,4,7,9,10,11} (issue ports 0..5), mc (multi-cycle: MUL/DIV/FPU) = {0,3,5,6,8},
#   agu = 12..19 (LD 12..15, STA 16..19), sdu = 20..23, bru = 24..27, CSR FU = 2 (no compute: needs no FU-side signals).
# Single-cycle FUs (ALU/AGU/SDU/BRU/CSR, SingleCycleFU in AbstractFU.h) have complete == en and ready == !en||consume by construction,
# so exu_ctrl does not take complete/ready from them: it hands them the compute operands and takes back only the computed fields;
# every pass-through field of ExuInst (dest_preg, rob_idx, ...) is taken from the control slot. The multi-cycle FUs (FixedLatencyFU/
# IterativeFU) keep their own state, so they get the full instruction and return {ready, complete, result, dest_preg, dest_en, br_mask, rob_idx}.
# Fields not listed have no reader (see docs/modules/exu_ctrl.md section 4): dbg, ExuInst.page_fault_inst/flush_pipe (constant 0), ftq_resp_valid,
# src*_preg, src2_en, ftq_offset; op of fixed-op FUs (MUL/DIV/FP/CSR/LD/STA/STD) is a constant of the FU kind.
module exu_ctrl

# ---- global inputs
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred
in  dec_bcast_br_mask 64 @ bt.dec_bcast.br_mask
in  dec_bcast_clear_mask 64 @ bt.dec_bcast.clear_mask
in  csr2exe_rdata 32 @ bt.csr2exe.rdata

# ---- prf2exe (issued instructions; uop read only when valid: Exu::comb_pipeline)
in  prf2exe_iss_entry_valid 1 [22] @ bt.prf2exe.iss_entry[i0].valid
in  prf2exe_iss_entry_uop_pc 32 [22] @ bt.prf2exe.iss_entry[i0].uop.pc
in  prf2exe_iss_entry_uop_ftq_pred_taken 1 [22] @ bt.prf2exe.iss_entry[i0].uop.ftq_pred_taken
in  prf2exe_iss_entry_uop_ftq_next_pc 32 [22] @ bt.prf2exe.iss_entry[i0].uop.ftq_next_pc
in  prf2exe_iss_entry_uop_dest_preg 7 [22] @ bt.prf2exe.iss_entry[i0].uop.dest_preg
in  prf2exe_iss_entry_uop_src1_rdata 32 [22] @ bt.prf2exe.iss_entry[i0].uop.src1_rdata
in  prf2exe_iss_entry_uop_src2_rdata 32 [22] @ bt.prf2exe.iss_entry[i0].uop.src2_rdata
in  prf2exe_iss_entry_uop_ftq_idx 6 [22] @ bt.prf2exe.iss_entry[i0].uop.ftq_idx
in  prf2exe_iss_entry_uop_is_atomic 1 [22] @ bt.prf2exe.iss_entry[i0].uop.is_atomic
in  prf2exe_iss_entry_uop_dest_en 1 [22] @ bt.prf2exe.iss_entry[i0].uop.dest_en
in  prf2exe_iss_entry_uop_src1_en 1 [22] @ bt.prf2exe.iss_entry[i0].uop.src1_en
in  prf2exe_iss_entry_uop_src1_is_pc 1 [22] @ bt.prf2exe.iss_entry[i0].uop.src1_is_pc
in  prf2exe_iss_entry_uop_src2_is_imm 1 [22] @ bt.prf2exe.iss_entry[i0].uop.src2_is_imm
in  prf2exe_iss_entry_uop_func3 3 [22] @ bt.prf2exe.iss_entry[i0].uop.func3
in  prf2exe_iss_entry_uop_func7 7 [22] @ bt.prf2exe.iss_entry[i0].uop.func7
in  prf2exe_iss_entry_uop_imm 32 [22] @ bt.prf2exe.iss_entry[i0].uop.imm
in  prf2exe_iss_entry_uop_br_id 6 [22] @ bt.prf2exe.iss_entry[i0].uop.br_id
in  prf2exe_iss_entry_uop_br_mask 64 [22] @ bt.prf2exe.iss_entry[i0].uop.br_mask
in  prf2exe_iss_entry_uop_rob_idx 7 [22] @ bt.prf2exe.iss_entry[i0].uop.rob_idx
in  prf2exe_iss_entry_uop_stq_idx 6 [22] @ bt.prf2exe.iss_entry[i0].uop.stq_idx
in  prf2exe_iss_entry_uop_stq_flag 1 [22] @ bt.prf2exe.iss_entry[i0].uop.stq_flag
in  prf2exe_iss_entry_uop_ldq_idx 6 [22] @ bt.prf2exe.iss_entry[i0].uop.ldq_idx
in  prf2exe_iss_entry_uop_rob_flag 1 [22] @ bt.prf2exe.iss_entry[i0].uop.rob_flag
in  prf2exe_iss_entry_uop_op 5 [22] @ bt.prf2exe.iss_entry[i0].uop.op
# csr_idx is only read for the CSR slot, which is hard-bound to issue port 0 (config.h:373)
in  prf2exe_iss_entry_uop_csr_idx 12 @ bt.prf2exe.iss_entry[0].uop.csr_idx

# ---- FU side (inputs): results of the single-cycle FUs and the full handshake of the multi-cycle FUs
in  fu_alu_result 32 [6] @ bt.exu->in.fu2exu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.result
in  fu_agu_result 32 [8] @ bt.exu->in.fu2exu->entry[12+i0].inst.result
in  fu_sdu_result 32 [4] @ bt.exu->in.fu2exu->entry[20+i0].inst.result
in  fu_bru_diag_val 32 [4] @ bt.exu->in.fu2exu->entry[24+i0].inst.diag_val
in  fu_bru_mispred 1 [4] @ bt.exu->in.fu2exu->entry[24+i0].inst.mispred
in  fu_bru_br_taken 1 [4] @ bt.exu->in.fu2exu->entry[24+i0].inst.br_taken
in  fu_mc_ready 1 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].ready
in  fu_mc_complete 1 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].complete
in  fu_mc_result 32 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.result
in  fu_mc_dest_preg 7 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.dest_preg
in  fu_mc_dest_en 1 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.dest_en
in  fu_mc_br_mask 64 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.br_mask
in  fu_mc_rob_idx 7 [5] @ bt.exu->in.fu2exu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.rob_idx

# ---- lsu2exe (write-back requests of loads / store-address / SC; op, flush_pipe, STA dest_preg/dest_en are per-port constants of the Lsu)
in  lsu2exe_wb_req_uop_diag_val 32 [4] @ bt.lsu2exe.wb_req[i0].uop.diag_val
in  lsu2exe_wb_req_uop_result 32 [4] @ bt.lsu2exe.wb_req[i0].uop.result
in  lsu2exe_wb_req_uop_dest_preg 7 [4] @ bt.lsu2exe.wb_req[i0].uop.dest_preg
in  lsu2exe_wb_req_uop_br_mask 64 [4] @ bt.lsu2exe.wb_req[i0].uop.br_mask
in  lsu2exe_wb_req_uop_rob_idx 7 [4] @ bt.lsu2exe.wb_req[i0].uop.rob_idx
in  lsu2exe_wb_req_uop_dest_en 1 [4] @ bt.lsu2exe.wb_req[i0].uop.dest_en
in  lsu2exe_wb_req_uop_page_fault_load 1 [4] @ bt.lsu2exe.wb_req[i0].uop.page_fault_load
in  lsu2exe_wb_req_uop_page_fault_store 1 [4] @ bt.lsu2exe.wb_req[i0].uop.page_fault_store
in  lsu2exe_wb_req_valid 1 [4] @ bt.lsu2exe.wb_req[i0].valid
in  lsu2exe_sta_wb_req_valid 1 [4] @ bt.lsu2exe.sta_wb_req[i0].valid
in  lsu2exe_sta_wb_req_uop_diag_val 32 [4] @ bt.lsu2exe.sta_wb_req[i0].uop.diag_val
in  lsu2exe_sta_wb_req_uop_result 32 [4] @ bt.lsu2exe.sta_wb_req[i0].uop.result
in  lsu2exe_sta_wb_req_uop_br_mask 64 [4] @ bt.lsu2exe.sta_wb_req[i0].uop.br_mask
in  lsu2exe_sta_wb_req_uop_rob_idx 7 [4] @ bt.lsu2exe.sta_wb_req[i0].uop.rob_idx
in  lsu2exe_sta_wb_req_uop_page_fault_store 1 [4] @ bt.lsu2exe.sta_wb_req[i0].uop.page_fault_store

# ================= outputs
# ---- exe2csr (idx is read when we|re, wdata/wcmd when we: Csr.cpp:75,340)
out exe2csr_we 1 @ bt.exe2csr.we
out exe2csr_re 1 @ bt.exe2csr.re
out exe2csr_idx 12 @ bt.exe2csr.idx
out exe2csr_wdata 32 when exe2csr_we @ bt.exe2csr.wdata
out exe2csr_wcmd 2 when exe2csr_we @ bt.exe2csr.wcmd

# ---- exe2iss
out exe2iss_fu_ready_mask 18 [22] @ bt.exe2iss.fu_ready_mask[i0]

# ---- exe2prf (Prf reads uop only when valid: Prf.cpp:33,203; bypass reads dest_en/dest_preg/result only)
out exe2prf_entry_valid 1 [22] @ bt.exe2prf.entry[i0].valid
out exe2prf_entry_uop_dest_preg 7 [22] when exe2prf_entry_valid @ bt.exe2prf.entry[i0].uop.dest_preg
out exe2prf_entry_uop_result 32 [22] when exe2prf_entry_valid @ bt.exe2prf.entry[i0].uop.result
out exe2prf_entry_uop_br_mask 64 [22] when exe2prf_entry_valid @ bt.exe2prf.entry[i0].uop.br_mask
out exe2prf_entry_uop_dest_en 1 [22] when exe2prf_entry_valid @ bt.exe2prf.entry[i0].uop.dest_en
out exe2prf_entry_uop_op 5 [22] when exe2prf_entry_valid @ bt.exe2prf.entry[i0].uop.op
out exe2prf_bypass_valid 1 [28] @ bt.exe2prf.bypass[i0].valid
out exe2prf_bypass_uop_dest_preg 7 [28] when exe2prf_bypass_valid @ bt.exe2prf.bypass[i0].uop.dest_preg
out exe2prf_bypass_uop_result 32 [28] when exe2prf_bypass_valid @ bt.exe2prf.bypass[i0].uop.result
out exe2prf_bypass_uop_dest_en 1 [28] when exe2prf_bypass_valid @ bt.exe2prf.bypass[i0].uop.dest_en

# ---- exu2rob (Rob::comb_complete reads rob_idx/op of every valid entry; result/diag_val/page_fault_* only for LD/STA ports 6..13,
#      diag_val/mispred/br_taken also for branch ports 18..21 (is_branch_uop); the other positions have no reader and are masked to 0 here;
#      page_fault_inst and flush_pipe are constant 0 and dropped)
out exu2rob_entry_valid 1 [22] @ bt.exu2rob.entry[i0].valid
out exu2rob_entry_uop_rob_idx 7 [22] when exu2rob_entry_valid @ bt.exu2rob.entry[i0].uop.rob_idx
out exu2rob_entry_uop_op 5 [22] when exu2rob_entry_valid @ bt.exu2rob.entry[i0].uop.op
out exu2rob_entry_uop_diag_val 32 [22] when exu2rob_entry_valid @ ((i0>=6&&i0<14)||(i0>=18)) ? (uint64_t)bt.exu2rob.entry[i0].uop.diag_val : 0
out exu2rob_entry_uop_result 32 [22] when exu2rob_entry_valid @ (i0>=6&&i0<14) ? (uint64_t)bt.exu2rob.entry[i0].uop.result : 0
out exu2rob_entry_uop_mispred 1 [22] when exu2rob_entry_valid @ (i0>=18) ? (uint64_t)bt.exu2rob.entry[i0].uop.mispred : 0
out exu2rob_entry_uop_br_taken 1 [22] when exu2rob_entry_valid @ (i0>=18) ? (uint64_t)bt.exu2rob.entry[i0].uop.br_taken : 0
out exu2rob_entry_uop_page_fault_load 1 [22] when exu2rob_entry_valid @ (i0>=6&&i0<14) ? (uint64_t)bt.exu2rob.entry[i0].uop.page_fault_load : 0
out exu2rob_entry_uop_page_fault_store 1 [22] when exu2rob_entry_valid @ (i0>=6&&i0<14) ? (uint64_t)bt.exu2rob.entry[i0].uop.page_fault_store : 0

# ---- exe2lsu (field set = what RealLsu reads, see spec/lsu.io; uop read only when valid)
out exe2lsu_ldu_req_valid 1 [4] @ bt.exe2lsu.agu_req[i0+0].valid
out exe2lsu_ldu_req_uop_result 32 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.result
out exe2lsu_ldu_req_uop_dest_preg 7 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.dest_preg
out exe2lsu_ldu_req_uop_func3 3 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.func3
out exe2lsu_ldu_req_uop_is_atomic 1 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.is_atomic
out exe2lsu_ldu_req_uop_amo_op 5 [4] when exe2lsu_ldu_req_valid @ (bt.exe2lsu.agu_req[i0+0].uop.func7 >> 2)
out exe2lsu_ldu_req_uop_rob_idx 7 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.rob_idx
out exe2lsu_ldu_req_uop_rob_flag 1 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.rob_flag
out exe2lsu_ldu_req_uop_stq_idx 6 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.stq_idx
out exe2lsu_ldu_req_uop_stq_flag 1 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.stq_flag
out exe2lsu_ldu_req_uop_ldq_idx 6 [4] when exe2lsu_ldu_req_valid @ bt.exe2lsu.agu_req[i0+0].uop.ldq_idx
out exe2lsu_sta_req_valid 1 [4] @ bt.exe2lsu.agu_req[i0+4].valid
out exe2lsu_sta_req_uop_result 32 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.result
out exe2lsu_sta_req_uop_dest_preg 7 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.dest_preg
out exe2lsu_sta_req_uop_func3 3 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.func3
out exe2lsu_sta_req_uop_is_atomic 1 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.is_atomic
out exe2lsu_sta_req_uop_amo_op 5 [4] when exe2lsu_sta_req_valid @ (bt.exe2lsu.agu_req[i0+4].uop.func7 >> 2)
out exe2lsu_sta_req_uop_rob_idx 7 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.rob_idx
out exe2lsu_sta_req_uop_rob_flag 1 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.rob_flag
out exe2lsu_sta_req_uop_stq_idx 6 [4] when exe2lsu_sta_req_valid @ bt.exe2lsu.agu_req[i0+4].uop.stq_idx
out exe2lsu_sdu_req_valid 1 [4] @ bt.exe2lsu.sdu_req[i0].valid
out exe2lsu_sdu_req_uop_result 32 [4] when exe2lsu_sdu_req_valid @ bt.exe2lsu.sdu_req[i0].uop.result
out exe2lsu_sdu_req_uop_rob_idx 7 [4] when exe2lsu_sdu_req_valid @ bt.exe2lsu.sdu_req[i0].uop.rob_idx
out exe2lsu_sdu_req_uop_rob_flag 1 [4] when exe2lsu_sdu_req_valid @ bt.exe2lsu.sdu_req[i0].uop.rob_flag
out exe2lsu_sdu_req_uop_stq_idx 6 [4] when exe2lsu_sdu_req_valid @ bt.exe2lsu.sdu_req[i0].uop.stq_idx

# ---- exu2id (Idu latches the whole struct; redirect fields are read only under mispred: docs/modules/idu.md)
out exu2id_mispred 1 @ bt.exu2id.mispred
out exu2id_clear_mask 64 @ bt.exu2id.clear_mask
out exu2id_redirect_pc 32 when exu2id_mispred @ bt.exu2id.redirect_pc
out exu2id_redirect_rob_idx 7 when exu2id_mispred @ bt.exu2id.redirect_rob_idx
out exu2id_br_id 6 when exu2id_mispred @ bt.exu2id.br_id
out exu2id_ftq_idx 6 when exu2id_mispred @ bt.exu2id.ftq_idx

# ---- exu2fu (to the FUs). flush/clear are identical for all 28 FUs (Exu::comb_fu_ctrl): one copy. Instruction fields only where en.
out exu2fu_flush 1 @ bt.exu->out.exu2fu->entry[0].flush
out exu2fu_flush_mask 64 when exu2fu_flush @ bt.exu->out.exu2fu->entry[0].flush_mask
out exu2fu_clear_mask 64 @ bt.exu->out.exu2fu->entry[0].clear_mask
out exu2fu_alu_en 1 [6] @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].en
out exu2fu_alu_op 5 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.op
out exu2fu_alu_func3 3 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.func3
out exu2fu_alu_func7 7 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.func7
out exu2fu_alu_src1_is_pc 1 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.src1_is_pc
out exu2fu_alu_src2_is_imm 1 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.src2_is_imm
out exu2fu_alu_pc 32 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.pc
out exu2fu_alu_imm 32 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.imm
out exu2fu_alu_src1_rdata 32 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.src1_rdata
out exu2fu_alu_src2_rdata 32 [6] when exu2fu_alu_en @ bt.exu->out.exu2fu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.src2_rdata
out exu2fu_bru_en 1 [4] @ bt.exu->out.exu2fu->entry[24+i0].en
out exu2fu_bru_op 5 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.op
out exu2fu_bru_func3 3 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.func3
out exu2fu_bru_src1_en 1 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.src1_en
out exu2fu_bru_src1_rdata 32 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.src1_rdata
out exu2fu_bru_src2_rdata 32 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.src2_rdata
out exu2fu_bru_pc 32 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.pc
out exu2fu_bru_imm 32 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.imm
out exu2fu_bru_ftq_pred_taken 1 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.ftq_pred_taken
out exu2fu_bru_ftq_next_pc 32 [4] when exu2fu_bru_en @ bt.exu->out.exu2fu->entry[24+i0].inst.ftq_next_pc
out exu2fu_agu_en 1 [8] @ bt.exu->out.exu2fu->entry[12+i0].en
out exu2fu_agu_src1_rdata 32 [8] when exu2fu_agu_en @ bt.exu->out.exu2fu->entry[12+i0].inst.src1_rdata
out exu2fu_agu_imm 32 [8] when exu2fu_agu_en @ bt.exu->out.exu2fu->entry[12+i0].inst.imm
out exu2fu_sdu_en 1 [4] @ bt.exu->out.exu2fu->entry[20+i0].en
out exu2fu_sdu_is_atomic 1 [4] when exu2fu_sdu_en @ bt.exu->out.exu2fu->entry[20+i0].inst.is_atomic
out exu2fu_sdu_func7 7 [4] when exu2fu_sdu_en @ bt.exu->out.exu2fu->entry[20+i0].inst.func7
out exu2fu_sdu_src1_rdata 32 [4] when exu2fu_sdu_en @ bt.exu->out.exu2fu->entry[20+i0].inst.src1_rdata
out exu2fu_sdu_src2_rdata 32 [4] when exu2fu_sdu_en @ bt.exu->out.exu2fu->entry[20+i0].inst.src2_rdata
out exu2fu_mc_en 1 [5] @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].en
out exu2fu_mc_consume 1 [5] @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].consume
out exu2fu_mc_func3 3 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.func3
out exu2fu_mc_func7 7 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.func7
out exu2fu_mc_op 5 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.op
out exu2fu_mc_imm 32 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.imm
out exu2fu_mc_src1_rdata 32 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.src1_rdata
out exu2fu_mc_src2_rdata 32 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.src2_rdata
out exu2fu_mc_dest_preg 7 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.dest_preg
out exu2fu_mc_dest_en 1 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.dest_en
out exu2fu_mc_br_mask 64 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.br_mask
out exu2fu_mc_rob_idx 7 [5] when exu2fu_mc_en @ bt.exu->out.exu2fu->entry[std::array<int,5>{0,3,5,6,8}[i0]].inst.rob_idx
