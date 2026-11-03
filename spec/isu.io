# Isu (back-end/Isu.cpp + include/IssueQueue.h): 5 issue queues, wake-up, select, delayed (MUL/DIV/FP) wake-up.
# Generated once by a helper script; committed as a plain spec.
# Omitted on purpose: dbg (debug sideband); exe2iss only fu_ready_mask is read; rob_bcast only flush; dec_bcast only mispred/br_mask/clear_mask.
# Consumers: dis2iss uop is read by Isu::comb_enq only when req.valid; iss2prf uop is read by Prf::comb_req_ftq / comb_read only when
# iss_entry.valid; iss_awake preg is read by Dispatch (is_preg_woken, comb_wake) and Isu::apply_wakeup_to_uop only when wake.valid.
module isu

in  dis2iss_req_valid 1 [5] [8] @ bt.dis2iss.req[i0][i1].valid
in  dis2iss_req_uop_dest_preg 7 [5] [8] @ bt.dis2iss.req[i0][i1].uop.dest_preg
in  dis2iss_req_uop_src1_preg 7 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src1_preg
in  dis2iss_req_uop_src2_preg 7 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src2_preg
in  dis2iss_req_uop_ftq_idx 6 [5] [8] @ bt.dis2iss.req[i0][i1].uop.ftq_idx
in  dis2iss_req_uop_ftq_offset 4 [5] [8] @ bt.dis2iss.req[i0][i1].uop.ftq_offset
in  dis2iss_req_uop_is_atomic 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.is_atomic
in  dis2iss_req_uop_dest_en 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.dest_en
in  dis2iss_req_uop_src1_en 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src1_en
in  dis2iss_req_uop_src2_en 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src2_en
in  dis2iss_req_uop_src1_busy 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src1_busy
in  dis2iss_req_uop_src2_busy 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src2_busy
in  dis2iss_req_uop_src1_is_pc 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src1_is_pc
in  dis2iss_req_uop_src2_is_imm 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.src2_is_imm
in  dis2iss_req_uop_func3 3 [5] [8] @ bt.dis2iss.req[i0][i1].uop.func3
in  dis2iss_req_uop_func7 7 [5] [8] @ bt.dis2iss.req[i0][i1].uop.func7
in  dis2iss_req_uop_imm 32 [5] [8] @ bt.dis2iss.req[i0][i1].uop.imm
in  dis2iss_req_uop_br_id 6 [5] [8] @ bt.dis2iss.req[i0][i1].uop.br_id
in  dis2iss_req_uop_br_mask 64 [5] [8] @ bt.dis2iss.req[i0][i1].uop.br_mask
in  dis2iss_req_uop_csr_idx 12 [5] [8] @ bt.dis2iss.req[i0][i1].uop.csr_idx
in  dis2iss_req_uop_rob_idx 7 [5] [8] @ bt.dis2iss.req[i0][i1].uop.rob_idx
in  dis2iss_req_uop_stq_idx 6 [5] [8] @ bt.dis2iss.req[i0][i1].uop.stq_idx
in  dis2iss_req_uop_stq_flag 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.stq_flag
in  dis2iss_req_uop_ldq_idx 6 [5] [8] @ bt.dis2iss.req[i0][i1].uop.ldq_idx
in  dis2iss_req_uop_rob_flag 1 [5] [8] @ bt.dis2iss.req[i0][i1].uop.rob_flag
in  dis2iss_req_uop_op 5 [5] [8] @ bt.dis2iss.req[i0][i1].uop.op
in  prf_awake_wake_valid 1 [4] @ bt.prf_awake.wake[i0].valid
in  prf_awake_wake_preg 7 [4] @ bt.prf_awake.wake[i0].preg
in  exe2iss_fu_ready_mask 18 [22] @ bt.exe2iss.fu_ready_mask[i0]
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred
in  dec_bcast_br_mask 64 @ bt.dec_bcast.br_mask
in  dec_bcast_clear_mask 64 @ bt.dec_bcast.clear_mask
out iss2dis_ready_num 8 [5] @ bt.iss2dis.ready_num[i0]
out iss2prf_iss_entry_valid 1 [22] @ bt.iss2prf.iss_entry[i0].valid
out iss2prf_iss_entry_uop_dest_preg 7 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.dest_preg
out iss2prf_iss_entry_uop_src1_preg 7 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.src1_preg
out iss2prf_iss_entry_uop_src2_preg 7 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.src2_preg
out iss2prf_iss_entry_uop_ftq_idx 6 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.ftq_idx
out iss2prf_iss_entry_uop_ftq_offset 4 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.ftq_offset
out iss2prf_iss_entry_uop_is_atomic 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.is_atomic
out iss2prf_iss_entry_uop_dest_en 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.dest_en
out iss2prf_iss_entry_uop_src1_en 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.src1_en
out iss2prf_iss_entry_uop_src2_en 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.src2_en
out iss2prf_iss_entry_uop_src1_is_pc 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.src1_is_pc
out iss2prf_iss_entry_uop_src2_is_imm 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.src2_is_imm
out iss2prf_iss_entry_uop_func3 3 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.func3
out iss2prf_iss_entry_uop_func7 7 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.func7
out iss2prf_iss_entry_uop_imm 32 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.imm
out iss2prf_iss_entry_uop_br_id 6 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.br_id
out iss2prf_iss_entry_uop_br_mask 64 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.br_mask
out iss2prf_iss_entry_uop_csr_idx 12 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.csr_idx
out iss2prf_iss_entry_uop_rob_idx 7 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.rob_idx
out iss2prf_iss_entry_uop_stq_idx 6 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.stq_idx
out iss2prf_iss_entry_uop_stq_flag 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.stq_flag
out iss2prf_iss_entry_uop_ldq_idx 6 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.ldq_idx
out iss2prf_iss_entry_uop_rob_flag 1 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.rob_flag
out iss2prf_iss_entry_uop_op 5 [22] when iss2prf_iss_entry_valid @ bt.iss2prf.iss_entry[i0].uop.op
out iss_awake_wake_valid 1 [15] @ bt.iss_awake.wake[i0].valid
out iss_awake_wake_preg 7 [15] when iss_awake_wake_valid @ bt.iss_awake.wake[i0].preg
