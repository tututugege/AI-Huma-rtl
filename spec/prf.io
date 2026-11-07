# Prf (physical register file + writeback pipe regs + operand read/bypass). Ref: back-end/Prf.cpp
# Boundary = BackTop wires iss2prf, exe2prf, dec_bcast, rob_bcast, ftq_prf_pc_resp -> prf2exe, prf_awake, ftq_prf_pc_req.
# dbg (DebugMeta) fields are not translated; prf2exe fields without an Exu/Lsu consumer are dropped (see docs/modules/prf.md). Inputs record the raw wire.
module prf

in  dec_bcast_mispred 1  @ bt.dec_bcast.mispred
in  dec_bcast_br_mask 64  @ bt.dec_bcast.br_mask
in  dec_bcast_clear_mask 64  @ bt.dec_bcast.clear_mask
in  rob_bcast_flush 1  @ bt.rob_bcast.flush
in  iss2prf_iss_entry_valid 1 [22] @ bt.iss2prf.iss_entry[i0].valid
in  iss2prf_iss_entry_uop_dest_preg 7 [22] @ bt.iss2prf.iss_entry[i0].uop.dest_preg
in  iss2prf_iss_entry_uop_src1_preg 7 [22] @ bt.iss2prf.iss_entry[i0].uop.src1_preg
in  iss2prf_iss_entry_uop_src2_preg 7 [22] @ bt.iss2prf.iss_entry[i0].uop.src2_preg
in  iss2prf_iss_entry_uop_ftq_idx 6 [22] @ bt.iss2prf.iss_entry[i0].uop.ftq_idx
in  iss2prf_iss_entry_uop_ftq_offset 4 [22] @ bt.iss2prf.iss_entry[i0].uop.ftq_offset
in  iss2prf_iss_entry_uop_is_atomic 1 [22] @ bt.iss2prf.iss_entry[i0].uop.is_atomic
in  iss2prf_iss_entry_uop_dest_en 1 [22] @ bt.iss2prf.iss_entry[i0].uop.dest_en
in  iss2prf_iss_entry_uop_src1_en 1 [22] @ bt.iss2prf.iss_entry[i0].uop.src1_en
in  iss2prf_iss_entry_uop_src2_en 1 [22] @ bt.iss2prf.iss_entry[i0].uop.src2_en
in  iss2prf_iss_entry_uop_src1_is_pc 1 [22] @ bt.iss2prf.iss_entry[i0].uop.src1_is_pc
in  iss2prf_iss_entry_uop_src2_is_imm 1 [22] @ bt.iss2prf.iss_entry[i0].uop.src2_is_imm
in  iss2prf_iss_entry_uop_func3 3 [22] @ bt.iss2prf.iss_entry[i0].uop.func3
in  iss2prf_iss_entry_uop_func7 7 [22] @ bt.iss2prf.iss_entry[i0].uop.func7
in  iss2prf_iss_entry_uop_imm 32 [22] @ bt.iss2prf.iss_entry[i0].uop.imm
in  iss2prf_iss_entry_uop_br_id 6 [22] @ bt.iss2prf.iss_entry[i0].uop.br_id
in  iss2prf_iss_entry_uop_br_mask 64 [22] @ bt.iss2prf.iss_entry[i0].uop.br_mask
in  iss2prf_iss_entry_uop_csr_idx 12 [22] @ bt.iss2prf.iss_entry[i0].uop.csr_idx
in  iss2prf_iss_entry_uop_rob_idx 7 [22] @ bt.iss2prf.iss_entry[i0].uop.rob_idx
in  iss2prf_iss_entry_uop_stq_idx 6 [22] @ bt.iss2prf.iss_entry[i0].uop.stq_idx
in  iss2prf_iss_entry_uop_stq_flag 1 [22] @ bt.iss2prf.iss_entry[i0].uop.stq_flag
in  iss2prf_iss_entry_uop_ldq_idx 6 [22] @ bt.iss2prf.iss_entry[i0].uop.ldq_idx
in  iss2prf_iss_entry_uop_rob_flag 1 [22] @ bt.iss2prf.iss_entry[i0].uop.rob_flag
in  iss2prf_iss_entry_uop_op 5 [22] @ bt.iss2prf.iss_entry[i0].uop.op
in  exe2prf_entry_valid 1 [22] @ bt.exe2prf.entry[i0].valid
in  exe2prf_entry_uop_dest_preg 7 [22] @ bt.exe2prf.entry[i0].uop.dest_preg
in  exe2prf_entry_uop_result 32 [22] @ bt.exe2prf.entry[i0].uop.result
in  exe2prf_entry_uop_br_mask 64 [22] @ bt.exe2prf.entry[i0].uop.br_mask
in  exe2prf_entry_uop_dest_en 1 [22] @ bt.exe2prf.entry[i0].uop.dest_en
in  exe2prf_entry_uop_op 5 [22] @ bt.exe2prf.entry[i0].uop.op
in  exe2prf_bypass_valid 1 [28] @ bt.exe2prf.bypass[i0].valid
# RTL-only data bypass of the LSU write-back requests (LP_L2 speculative wake-up with the L3 register); the model has no data path
in  lsu_byp_valid 1 [4] @ 0
in  lsu_byp_dest_preg 7 [4] @ 0
in  lsu_byp_result 32 [4] @ 0
in  exe2prf_bypass_uop_dest_preg 7 [28] @ bt.exe2prf.bypass[i0].uop.dest_preg
in  exe2prf_bypass_uop_result 32 [28] @ bt.exe2prf.bypass[i0].uop.result
in  exe2prf_bypass_uop_dest_en 1 [28] @ bt.exe2prf.bypass[i0].uop.dest_en
in  ftq_prf_pc_resp_resp_pc 32 [10] @ bt.ftq_prf_pc_resp.resp[i0].pc
in  ftq_prf_pc_resp_resp_pred_taken 1 [10] @ bt.ftq_prf_pc_resp.resp[i0].pred_taken
in  ftq_prf_pc_resp_resp_next_pc 32 [10] @ bt.ftq_prf_pc_resp.resp[i0].next_pc
out ftq_prf_pc_req_req_valid 1 [10] @ bt.ftq_prf_pc_req.req[i0].valid
out ftq_prf_pc_req_req_ftq_idx 6 [10] when ftq_prf_pc_req_req_valid @ bt.ftq_prf_pc_req.req[i0].ftq_idx
out ftq_prf_pc_req_req_ftq_offset 4 [10] when ftq_prf_pc_req_req_valid @ bt.ftq_prf_pc_req.req[i0].ftq_offset
out prf_awake_wake_valid 1 [4] @ bt.prf_awake.wake[i0].valid
out prf_awake_wake_preg 7 [4] when prf_awake_wake_valid @ bt.prf_awake.wake[i0].preg
out prf2exe_iss_entry_valid 1 [22] @ bt.prf2exe.iss_entry[i0].valid
out prf2exe_iss_entry_uop_pc 32 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.pc
out prf2exe_iss_entry_uop_ftq_pred_taken 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.ftq_pred_taken
out prf2exe_iss_entry_uop_ftq_next_pc 32 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.ftq_next_pc
out prf2exe_iss_entry_uop_src1_rdata 32 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.src1_rdata
out prf2exe_iss_entry_uop_src2_rdata 32 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.src2_rdata
out prf2exe_iss_entry_uop_dest_preg 7 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.dest_preg
out prf2exe_iss_entry_uop_ftq_idx 6 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.ftq_idx
out prf2exe_iss_entry_uop_is_atomic 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.is_atomic
out prf2exe_iss_entry_uop_dest_en 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.dest_en
out prf2exe_iss_entry_uop_src1_en 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.src1_en
out prf2exe_iss_entry_uop_src1_is_pc 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.src1_is_pc
out prf2exe_iss_entry_uop_src2_is_imm 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.src2_is_imm
out prf2exe_iss_entry_uop_func3 3 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.func3
out prf2exe_iss_entry_uop_func7 7 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.func7
out prf2exe_iss_entry_uop_imm 32 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.imm
out prf2exe_iss_entry_uop_br_id 6 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.br_id
out prf2exe_iss_entry_uop_br_mask 64 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.br_mask
out prf2exe_iss_entry_uop_csr_idx 12 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.csr_idx
out prf2exe_iss_entry_uop_rob_idx 7 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.rob_idx
out prf2exe_iss_entry_uop_stq_idx 6 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.stq_idx
out prf2exe_iss_entry_uop_stq_flag 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.stq_flag
out prf2exe_iss_entry_uop_ldq_idx 6 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.ldq_idx
out prf2exe_iss_entry_uop_rob_flag 1 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.rob_flag
out prf2exe_iss_entry_uop_op 5 [22] when prf2exe_iss_entry_valid @ bt.prf2exe.iss_entry[i0].uop.op
