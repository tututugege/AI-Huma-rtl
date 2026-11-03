# Ref: back-end/Ren.cpp class Ren; wiring in back-end/BackTop.cpp (REN comb_begin/alloc/rename/fire/pipeline/seq)
module ren

in  dec2ren_valid 1 [8] @ bt.dec2ren.valid[i0]
in  dec2ren_uop_diag_val 32 [8] @ bt.dec2ren.uop[i0].diag_val
in  dec2ren_uop_dest_areg 6 [8] @ bt.dec2ren.uop[i0].dest_areg
in  dec2ren_uop_src1_areg 6 [8] @ bt.dec2ren.uop[i0].src1_areg
in  dec2ren_uop_src2_areg 6 [8] @ bt.dec2ren.uop[i0].src2_areg
in  dec2ren_uop_ftq_idx 6 [8] @ bt.dec2ren.uop[i0].ftq_idx
in  dec2ren_uop_ftq_offset 4 [8] @ bt.dec2ren.uop[i0].ftq_offset
in  dec2ren_uop_ftq_is_last 1 [8] @ bt.dec2ren.uop[i0].ftq_is_last
in  dec2ren_uop_type 5 [8] @ bt.dec2ren.uop[i0].type
in  dec2ren_uop_dest_en 1 [8] @ bt.dec2ren.uop[i0].dest_en
in  dec2ren_uop_src1_en 1 [8] @ bt.dec2ren.uop[i0].src1_en
in  dec2ren_uop_src2_en 1 [8] @ bt.dec2ren.uop[i0].src2_en
in  dec2ren_uop_is_atomic 1 [8] @ bt.dec2ren.uop[i0].is_atomic
in  dec2ren_uop_src1_is_pc 1 [8] @ bt.dec2ren.uop[i0].src1_is_pc
in  dec2ren_uop_src2_is_imm 1 [8] @ bt.dec2ren.uop[i0].src2_is_imm
in  dec2ren_uop_func3 3 [8] @ bt.dec2ren.uop[i0].func3
in  dec2ren_uop_func7 7 [8] @ bt.dec2ren.uop[i0].func7
in  dec2ren_uop_imm 32 [8] @ bt.dec2ren.uop[i0].imm
in  dec2ren_uop_br_id 6 [8] @ bt.dec2ren.uop[i0].br_id
in  dec2ren_uop_br_mask 64 [8] @ bt.dec2ren.uop[i0].br_mask
in  dec2ren_uop_csr_idx 12 [8] @ bt.dec2ren.uop[i0].csr_idx
in  dec2ren_uop_page_fault_inst 1 [8] @ bt.dec2ren.uop[i0].page_fault_inst
in  dec2ren_uop_illegal_inst 1 [8] @ bt.dec2ren.uop[i0].illegal_inst
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred
in  dec_bcast_br_id 6 @ bt.dec_bcast.br_id
in  dec_bcast_clear_mask 64 @ bt.dec_bcast.clear_mask
in  dis2ren_ready 1 @ bt.dis2ren.ready
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  rob_bcast_interrupt 1 @ bt.rob_bcast.interrupt
in  rob_commit_commit_entry_valid 1 [8] @ bt.rob_commit.commit_entry[i0].valid
in  rob_commit_commit_entry_uop_dest_areg 6 [8] @ bt.rob_commit.commit_entry[i0].uop.dest_areg
in  rob_commit_commit_entry_uop_dest_preg 7 [8] @ bt.rob_commit.commit_entry[i0].uop.dest_preg
in  rob_commit_commit_entry_uop_old_dest_preg 7 [8] @ bt.rob_commit.commit_entry[i0].uop.old_dest_preg
in  rob_commit_commit_entry_uop_dest_en 1 [8] @ bt.rob_commit.commit_entry[i0].uop.dest_en
in  rob_commit_commit_entry_uop_type 5 [8] @ bt.rob_commit.commit_entry[i0].uop.type
in  rob_commit_commit_entry_uop_page_fault_inst 1 [8] @ bt.rob_commit.commit_entry[i0].uop.page_fault_inst
in  rob_commit_commit_entry_uop_page_fault_load 1 [8] @ bt.rob_commit.commit_entry[i0].uop.page_fault_load
in  rob_commit_commit_entry_uop_page_fault_store 1 [8] @ bt.rob_commit.commit_entry[i0].uop.page_fault_store
in  rob_commit_commit_entry_uop_illegal_inst 1 [8] @ bt.rob_commit.commit_entry[i0].uop.illegal_inst
out ren2dec_ready 1 @ bt.ren2dec.ready
out ren2dis_valid 1 [8] @ bt.ren2dis.valid[i0]
out ren2dis_uop_diag_val 32 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].diag_val
out ren2dis_uop_dest_areg 6 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].dest_areg
out ren2dis_uop_src1_areg 6 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src1_areg
out ren2dis_uop_ftq_idx 6 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].ftq_idx
out ren2dis_uop_ftq_offset 4 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].ftq_offset
out ren2dis_uop_ftq_is_last 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].ftq_is_last
out ren2dis_uop_type 5 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].type
out ren2dis_uop_dest_en 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].dest_en
out ren2dis_uop_src1_en 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src1_en
out ren2dis_uop_src2_en 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src2_en
out ren2dis_uop_is_atomic 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].is_atomic
out ren2dis_uop_src1_is_pc 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src1_is_pc
out ren2dis_uop_src2_is_imm 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src2_is_imm
out ren2dis_uop_func3 3 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].func3
out ren2dis_uop_func7 7 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].func7
out ren2dis_uop_imm 32 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].imm
out ren2dis_uop_br_id 6 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].br_id
out ren2dis_uop_br_mask 64 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].br_mask
out ren2dis_uop_csr_idx 12 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].csr_idx
out ren2dis_uop_page_fault_inst 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].page_fault_inst
out ren2dis_uop_illegal_inst 1 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].illegal_inst
out ren2dis_uop_dest_preg 7 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].dest_preg
out ren2dis_uop_src1_preg 7 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src1_preg
out ren2dis_uop_src2_preg 7 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].src2_preg
out ren2dis_uop_old_dest_preg 7 [8] when ren2dis_valid @ bt.ren2dis.uop[i0].old_dest_preg
