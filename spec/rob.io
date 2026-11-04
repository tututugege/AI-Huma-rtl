# Rob (back-end/Rob.cpp): reorder buffer. Boundary = Rob::comb_* inputs/outputs, recorded after BackTop::comb().
# Not translated (perf/debug/TB-perf only): dbg.*, tma.* (all), rob2dis.tma, lsu2rob miss_mask, is_atomic/func3, ftq resp.valid (assert only), commit flush_pipe (the field no longer exists: MMIO waits for the ROB head instead of flushing).
module rob

# ---- inputs ----
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred
in  dec_bcast_redirect_rob_idx 7 @ bt.dec_bcast.redirect_rob_idx
in  csr2rob_interrupt_req 1 @ bt.csr2rob.interrupt_req
in  lsu2rob_committed_store_pending 1 @ bt.lsu2rob.committed_store_pending
in  front_stall 1 @ bt.in.front_stall
in  ftq_rob_pc_resp_resp_pc 32 [1] @ bt.ftq_rob_pc_resp.resp[i0].pc
in  dis2rob_dis_fire 1 [8] @ bt.dis2rob.dis_fire[i0]
in  dis2rob_uop_diag_val 32 [8] @ bt.dis2rob.uop[i0].diag_val
in  dis2rob_uop_dest_areg 6 [8] @ bt.dis2rob.uop[i0].dest_areg
in  dis2rob_uop_src1_areg 6 [8] @ bt.dis2rob.uop[i0].src1_areg
in  dis2rob_uop_dest_preg 7 [8] @ bt.dis2rob.uop[i0].dest_preg
in  dis2rob_uop_old_dest_preg 7 [8] @ bt.dis2rob.uop[i0].old_dest_preg
in  dis2rob_uop_ftq_idx 6 [8] @ bt.dis2rob.uop[i0].ftq_idx
in  dis2rob_uop_ftq_offset 4 [8] @ bt.dis2rob.uop[i0].ftq_offset
in  dis2rob_uop_ftq_is_last 1 [8] @ bt.dis2rob.uop[i0].ftq_is_last
in  dis2rob_uop_type 5 [8] @ bt.dis2rob.uop[i0].type
in  dis2rob_uop_dest_en 1 [8] @ bt.dis2rob.uop[i0].dest_en
in  dis2rob_uop_func7 7 [8] @ bt.dis2rob.uop[i0].func7
in  dis2rob_uop_imm 32 [8] @ bt.dis2rob.uop[i0].imm
in  dis2rob_uop_rob_idx 7 [8] @ bt.dis2rob.uop[i0].rob_idx
in  dis2rob_uop_stq_idx 6 [8] @ bt.dis2rob.uop[i0].stq_idx
in  dis2rob_uop_stq_flag 1 [8] @ bt.dis2rob.uop[i0].stq_flag
in  dis2rob_uop_expect_mask 3 [8] @ bt.dis2rob.uop[i0].expect_mask
in  dis2rob_uop_rob_flag 1 [8] @ bt.dis2rob.uop[i0].rob_flag
in  dis2rob_uop_page_fault_inst 1 [8] @ bt.dis2rob.uop[i0].page_fault_inst
in  dis2rob_uop_illegal_inst 1 [8] @ bt.dis2rob.uop[i0].illegal_inst
in  exu2rob_entry_valid 1 [22] @ bt.exu2rob.entry[i0].valid
in  exu2rob_entry_uop_diag_val 32 [22] @ bt.exu2rob.entry[i0].uop.diag_val
in  exu2rob_entry_uop_result 32 [22] @ bt.exu2rob.entry[i0].uop.result
in  exu2rob_entry_uop_rob_idx 7 [22] @ bt.exu2rob.entry[i0].uop.rob_idx
in  exu2rob_entry_uop_mispred 1 [22] @ bt.exu2rob.entry[i0].uop.mispred
in  exu2rob_entry_uop_br_taken 1 [22] @ bt.exu2rob.entry[i0].uop.br_taken
in  exu2rob_entry_uop_page_fault_load 1 [22] @ bt.exu2rob.entry[i0].uop.page_fault_load
in  exu2rob_entry_uop_page_fault_store 1 [22] @ bt.exu2rob.entry[i0].uop.page_fault_store
in  exu2rob_entry_uop_op 5 [22] @ bt.exu2rob.entry[i0].uop.op

# ---- outputs ----
out rob2dis_stall 1 @ bt.rob2dis.stall
out rob2dis_empty 1 @ bt.rob2dis.empty
out rob2dis_ready 1 @ bt.rob2dis.ready
out rob2dis_enq_idx 7 @ bt.rob2dis.enq_idx
out rob2dis_rob_flag 1 @ bt.rob2dis.rob_flag
out rob2csr_commit 1 @ bt.rob2csr.commit
out rob2csr_interrupt_resp 1 @ bt.rob2csr.interrupt_resp
out rob_commit_commit_entry_valid 1 [8] @ bt.rob_commit.commit_entry[i0].valid
out rob_commit_commit_entry_uop_diag_val 32 [8] when rob_commit_commit_entry_valid @ bt.rob->entry[i0][(int)bt.rob->deq_ptr].uop.diag_val
out rob_commit_commit_entry_uop_dest_areg 6 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.dest_areg
out rob_commit_commit_entry_uop_dest_preg 7 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.dest_preg
out rob_commit_commit_entry_uop_old_dest_preg 7 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.old_dest_preg
out rob_commit_commit_entry_uop_ftq_idx 6 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.ftq_idx
out rob_commit_commit_entry_uop_ftq_offset 4 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.ftq_offset
out rob_commit_commit_entry_uop_ftq_is_last 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.ftq_is_last
out rob_commit_commit_entry_uop_mispred 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.mispred
out rob_commit_commit_entry_uop_br_taken 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.br_taken
out rob_commit_commit_entry_uop_dest_en 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.dest_en
out rob_commit_commit_entry_uop_func7 7 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.func7
out rob_commit_commit_entry_uop_rob_idx 7 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.rob_idx
out rob_commit_commit_entry_uop_rob_flag 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.rob_flag
out rob_commit_commit_entry_uop_stq_idx 6 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.stq_idx
out rob_commit_commit_entry_uop_stq_flag 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.stq_flag
out rob_commit_commit_entry_uop_page_fault_inst 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.page_fault_inst
out rob_commit_commit_entry_uop_page_fault_load 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.page_fault_load
out rob_commit_commit_entry_uop_page_fault_store 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.page_fault_store
out rob_commit_commit_entry_uop_illegal_inst 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.illegal_inst
out rob_commit_commit_entry_uop_type 5 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.type
out commit_extra_src1_areg 6 [8] when rob_commit_commit_entry_valid @ bt.rob->out.commit_extra[i0].src1_areg
out commit_extra_imm 32 [8] when rob_commit_commit_entry_valid @ bt.rob->out.commit_extra[i0].imm
out rob_bcast_flush 1 @ bt.rob_bcast.flush
out rob_bcast_mret 1 @ bt.rob_bcast.mret
out rob_bcast_sret 1 @ bt.rob_bcast.sret
out rob_bcast_ecall 1 @ bt.rob_bcast.ecall
out rob_bcast_breakpoint 1 @ 0
out rob_bcast_exception 1 @ bt.rob_bcast.exception
out rob_bcast_fence 1 @ bt.rob_bcast.fence
out rob_bcast_fence_i 1 @ bt.rob_bcast.fence_i
out rob_bcast_page_fault_inst 1 @ bt.rob_bcast.page_fault_inst
out rob_bcast_page_fault_load 1 @ bt.rob_bcast.page_fault_load
out rob_bcast_page_fault_store 1 @ bt.rob_bcast.page_fault_store
out rob_bcast_illegal_inst 1 @ bt.rob_bcast.illegal_inst
out rob_bcast_interrupt 1 @ bt.rob_bcast.interrupt
out rob_bcast_trap_val_valid 1 @ (bt.rob_bcast.page_fault_inst||bt.rob_bcast.page_fault_load||bt.rob_bcast.page_fault_store||bt.rob_bcast.illegal_inst)
out rob_bcast_trap_val 32 when rob_bcast_trap_val_valid @ bt.rob_bcast.trap_val
out rob_bcast_pc 32 when rob_bcast_flush @ bt.rob_bcast.pc
out rob_bcast_head_rob_idx 7 when rob_bcast_head_valid @ bt.rob_bcast.head_rob_idx
out rob_bcast_head_valid 1 @ bt.rob_bcast.head_valid
out rob_bcast_head_incomplete_rob_idx 7 when rob_bcast_head_incomplete_valid @ bt.rob_bcast.head_incomplete_rob_idx
out rob_bcast_head_incomplete_valid 1 @ bt.rob_bcast.head_incomplete_valid
out ftq_rob_pc_req_req_valid 1 [1] @ bt.ftq_rob_pc_req.req[i0].valid
out ftq_rob_pc_req_req_ftq_idx 6 [1] when ftq_rob_pc_req_req_valid @ bt.ftq_rob_pc_req.req[i0].ftq_idx
out ftq_rob_pc_req_req_ftq_offset 4 [1] when ftq_rob_pc_req_req_valid @ bt.ftq_rob_pc_req.req[i0].ftq_offset
