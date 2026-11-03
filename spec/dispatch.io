# Dispatch (back-end/Dispatch.cpp). Generated once by a helper script; committed as a plain spec.
# Omitted on purpose: tma/dbg (perf/debug), ren2dis expect_mask/cplt_mask/src2_areg (dead: overwritten or never read).
# Outputs are compared only where a consumer reads them: dis2rob.uop when dis_fire (Rob::comb_fire),
# dis2iss uop when req valid (Isu::comb_enq), dis2lsu payload when the alloc request is set (RealLsu::comb_dis2lsu).
# Dropped (no consumer / constant 0): dis2rob.valid, dis2rob.uop.{br_mask,ldq_idx,mispred,br_taken,flush_pipe,cplt_mask}.
module dispatch

in  ren2dis_valid 1 [8] @ bt.ren2dis.valid[i0]
in  ren2dis_uop_diag_val 32 [8] @ bt.ren2dis.uop[i0].diag_val
in  ren2dis_uop_dest_areg 6 [8] @ bt.ren2dis.uop[i0].dest_areg
in  ren2dis_uop_src1_areg 6 [8] @ bt.ren2dis.uop[i0].src1_areg
in  ren2dis_uop_dest_preg 7 [8] @ bt.ren2dis.uop[i0].dest_preg
in  ren2dis_uop_src1_preg 7 [8] @ bt.ren2dis.uop[i0].src1_preg
in  ren2dis_uop_src2_preg 7 [8] @ bt.ren2dis.uop[i0].src2_preg
in  ren2dis_uop_old_dest_preg 7 [8] @ bt.ren2dis.uop[i0].old_dest_preg
in  ren2dis_uop_ftq_idx 6 [8] @ bt.ren2dis.uop[i0].ftq_idx
in  ren2dis_uop_ftq_offset 4 [8] @ bt.ren2dis.uop[i0].ftq_offset
in  ren2dis_uop_ftq_is_last 1 [8] @ bt.ren2dis.uop[i0].ftq_is_last
in  ren2dis_uop_type 5 [8] @ bt.ren2dis.uop[i0].type
in  ren2dis_uop_dest_en 1 [8] @ bt.ren2dis.uop[i0].dest_en
in  ren2dis_uop_src1_en 1 [8] @ bt.ren2dis.uop[i0].src1_en
in  ren2dis_uop_src2_en 1 [8] @ bt.ren2dis.uop[i0].src2_en
in  ren2dis_uop_is_atomic 1 [8] @ bt.ren2dis.uop[i0].is_atomic
in  ren2dis_uop_src1_busy 1 [8] @ bt.ren2dis.uop[i0].src1_busy
in  ren2dis_uop_src2_busy 1 [8] @ bt.ren2dis.uop[i0].src2_busy
in  ren2dis_uop_src1_is_pc 1 [8] @ bt.ren2dis.uop[i0].src1_is_pc
in  ren2dis_uop_src2_is_imm 1 [8] @ bt.ren2dis.uop[i0].src2_is_imm
in  ren2dis_uop_func3 3 [8] @ bt.ren2dis.uop[i0].func3
in  ren2dis_uop_func7 7 [8] @ bt.ren2dis.uop[i0].func7
in  ren2dis_uop_imm 32 [8] @ bt.ren2dis.uop[i0].imm
in  ren2dis_uop_br_id 6 [8] @ bt.ren2dis.uop[i0].br_id
in  ren2dis_uop_br_mask 64 [8] @ bt.ren2dis.uop[i0].br_mask
in  ren2dis_uop_csr_idx 12 [8] @ bt.ren2dis.uop[i0].csr_idx
in  ren2dis_uop_page_fault_inst 1 [8] @ bt.ren2dis.uop[i0].page_fault_inst
in  ren2dis_uop_illegal_inst 1 [8] @ bt.ren2dis.uop[i0].illegal_inst
in  rob2dis_ready 1 @ bt.rob2dis.ready
in  rob2dis_empty 1 @ bt.rob2dis.empty
in  rob2dis_stall 1 @ bt.rob2dis.stall
in  rob2dis_enq_idx 7 @ bt.rob2dis.enq_idx
in  rob2dis_rob_flag 1 @ bt.rob2dis.rob_flag
in  iss2dis_ready_num 8 [5] @ bt.iss2dis.ready_num[i0]
in  lsu2dis_stq_tail 6 @ bt.lsu2dis.stq_tail
in  lsu2dis_stq_tail_flag 1 @ bt.lsu2dis.stq_tail_flag
in  lsu2dis_stq_free 7 @ bt.lsu2dis.stq_free
in  lsu2dis_ldq_free 7 @ bt.lsu2dis.ldq_free
in  lsu2dis_ldq_alloc_idx 6 [8] @ bt.lsu2dis.ldq_alloc_idx[i0]
in  lsu2dis_ldq_alloc_valid 1 [8] @ bt.lsu2dis.ldq_alloc_valid[i0]
in  prf_awake_wake_valid 1 [4] @ bt.prf_awake.wake[i0].valid
in  prf_awake_wake_preg 7 [4] @ bt.prf_awake.wake[i0].preg
in  iss_awake_wake_valid 1 [15] @ bt.iss_awake.wake[i0].valid
in  iss_awake_wake_preg 7 [15] @ bt.iss_awake.wake[i0].preg
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred
in  dec_bcast_clear_mask 64 @ bt.dec_bcast.clear_mask
out dis2ren_ready 1 @ bt.dis2ren.ready
out dis2rob_dis_fire 1 [8] @ bt.dis2rob.dis_fire[i0]
out dis2rob_uop_diag_val 32 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].diag_val
out dis2rob_uop_dest_areg 6 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].dest_areg
out dis2rob_uop_src1_areg 6 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].src1_areg
out dis2rob_uop_dest_preg 7 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].dest_preg
out dis2rob_uop_old_dest_preg 7 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].old_dest_preg
out dis2rob_uop_ftq_idx 6 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].ftq_idx
out dis2rob_uop_ftq_offset 4 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].ftq_offset
out dis2rob_uop_ftq_is_last 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].ftq_is_last
out dis2rob_uop_type 5 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].type
out dis2rob_uop_dest_en 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].dest_en
out dis2rob_uop_is_atomic 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].is_atomic
out dis2rob_uop_func3 3 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].func3
out dis2rob_uop_func7 7 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].func7
out dis2rob_uop_imm 32 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].imm
out dis2rob_uop_rob_idx 7 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].rob_idx
out dis2rob_uop_stq_idx 6 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].stq_idx
out dis2rob_uop_stq_flag 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].stq_flag
out dis2rob_uop_expect_mask 3 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].expect_mask
out dis2rob_uop_rob_flag 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].rob_flag
out dis2rob_uop_page_fault_inst 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].page_fault_inst
out dis2rob_uop_illegal_inst 1 [8] when dis2rob_dis_fire @ bt.dis2rob.uop[i0].illegal_inst
out dis2iss_req_valid 1 [5] [8] @ bt.dis2iss.req[i0][i1].valid
out dis2iss_req_uop_dest_preg 7 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.dest_preg
out dis2iss_req_uop_src1_preg 7 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src1_preg
out dis2iss_req_uop_src2_preg 7 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src2_preg
out dis2iss_req_uop_ftq_idx 6 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.ftq_idx
out dis2iss_req_uop_ftq_offset 4 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.ftq_offset
out dis2iss_req_uop_is_atomic 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.is_atomic
out dis2iss_req_uop_dest_en 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.dest_en
out dis2iss_req_uop_src1_en 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src1_en
out dis2iss_req_uop_src2_en 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src2_en
out dis2iss_req_uop_src1_busy 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src1_busy
out dis2iss_req_uop_src2_busy 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src2_busy
out dis2iss_req_uop_src1_is_pc 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src1_is_pc
out dis2iss_req_uop_src2_is_imm 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.src2_is_imm
out dis2iss_req_uop_func3 3 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.func3
out dis2iss_req_uop_func7 7 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.func7
out dis2iss_req_uop_imm 32 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.imm
out dis2iss_req_uop_br_id 6 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.br_id
out dis2iss_req_uop_br_mask 64 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.br_mask
out dis2iss_req_uop_csr_idx 12 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.csr_idx
out dis2iss_req_uop_rob_idx 7 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.rob_idx
out dis2iss_req_uop_stq_idx 6 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.stq_idx
out dis2iss_req_uop_stq_flag 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.stq_flag
out dis2iss_req_uop_ldq_idx 6 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.ldq_idx
out dis2iss_req_uop_rob_flag 1 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.rob_flag
out dis2iss_req_uop_op 5 [5] [8] when dis2iss_req_valid @ bt.dis2iss.req[i0][i1].uop.op
out dis2lsu_alloc_req 1 [8] @ bt.dis2lsu.alloc_req[i0]
out dis2lsu_br_mask 64 [8] when dis2lsu_alloc_req @ bt.dis2lsu.br_mask[i0]
out dis2lsu_func3 3 [8] when dis2lsu_alloc_req @ bt.dis2lsu.func3[i0]
out dis2lsu_rob_idx 7 [8] when dis2lsu_alloc_req @ bt.dis2lsu.rob_idx[i0]
out dis2lsu_rob_flag 1 [8] when dis2lsu_alloc_req @ bt.dis2lsu.rob_flag[i0]
out dis2lsu_stq_flag 1 [8] when dis2lsu_alloc_req @ bt.dis2lsu.stq_flag[i0]
out dis2lsu_ldq_alloc_req 1 [8] @ bt.dis2lsu.ldq_alloc_req[i0]
out dis2lsu_ldq_br_mask 64 [8] when dis2lsu_ldq_alloc_req @ bt.dis2lsu.ldq_br_mask[i0]
out dis2lsu_ldq_idx 6 [8] when dis2lsu_ldq_alloc_req @ bt.dis2lsu.ldq_idx[i0]
out dis2lsu_ldq_rob_idx 7 [8] when dis2lsu_ldq_alloc_req @ bt.dis2lsu.ldq_rob_idx[i0]
out dis2lsu_ldq_rob_flag 1 [8] when dis2lsu_ldq_alloc_req @ bt.dis2lsu.ldq_rob_flag[i0]
