# Idu: decode + branch tag/mask management. Ref: back-end/Idu.cpp class Idu (comb_branch/decode/fire + seq)
# Boundary = BackTop IDU(comb_begin/comb_branch/comb_decode/comb_fire/seq); trace point = end of comb, before seq.
module idu

# ---- inputs: PreIduQueue issue group (pc / dbg are not translated) ----
in  pre_issue_entries_valid 1 [8] @ bt.pre_issue.entries[i0].valid
in  pre_issue_entries_inst 32 [8] @ bt.pre_issue.entries[i0].inst
in  pre_issue_entries_page_fault_inst 1 [8] @ bt.pre_issue.entries[i0].page_fault_inst
in  pre_issue_entries_ftq_idx 6 [8] @ bt.pre_issue.entries[i0].ftq_idx
in  pre_issue_entries_ftq_offset 4 [8] @ bt.pre_issue.entries[i0].ftq_offset
in  pre_issue_entries_ftq_is_last 1 [8] @ bt.pre_issue.entries[i0].ftq_is_last

in  ren2dec_ready 1 @ bt.ren2dec.ready
in  rob_bcast_flush 1 @ bt.rob_bcast.flush

# ---- inputs: branch resolution from EXU (latched into br_latch inside Idu) ----
in  exu2id_mispred 1 @ bt.exu2id.mispred
in  exu2id_redirect_pc 32 @ bt.exu2id.redirect_pc
in  exu2id_redirect_rob_idx 7 @ bt.exu2id.redirect_rob_idx
in  exu2id_br_id 6 @ bt.exu2id.br_id
in  exu2id_ftq_idx 6 @ bt.exu2id.ftq_idx
in  exu2id_clear_mask 64 @ bt.exu2id.clear_mask

# ---- outputs: dec2ren (rename input group); uop payload only meaningful when the lane is valid ----
out dec2ren_valid 1 [8] @ bt.dec2ren.valid[i0]
out dec2ren_uop_diag_val 32 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].diag_val
out dec2ren_uop_dest_areg 6 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].dest_areg
out dec2ren_uop_src1_areg 6 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].src1_areg
out dec2ren_uop_src2_areg 6 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].src2_areg
out dec2ren_uop_ftq_idx 6 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].ftq_idx
out dec2ren_uop_ftq_offset 4 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].ftq_offset
out dec2ren_uop_ftq_is_last 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].ftq_is_last
out dec2ren_uop_type 5 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].type
out dec2ren_uop_dest_en 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].dest_en
out dec2ren_uop_src1_en 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].src1_en
out dec2ren_uop_src2_en 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].src2_en
out dec2ren_uop_is_atomic 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].is_atomic
out dec2ren_uop_src1_is_pc 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].src1_is_pc
out dec2ren_uop_src2_is_imm 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].src2_is_imm
out dec2ren_uop_func3 3 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].func3
out dec2ren_uop_func7 7 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].func7
out dec2ren_uop_imm 32 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].imm
out dec2ren_uop_br_id 6 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].br_id
out dec2ren_uop_br_mask 64 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].br_mask
out dec2ren_uop_csr_idx 12 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].csr_idx
out dec2ren_uop_page_fault_inst 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].page_fault_inst
out dec2ren_uop_illegal_inst 1 [8] when dec2ren_valid @ bt.dec2ren.uop[i0].illegal_inst

# ---- outputs: dec_bcast (br_mask/br_id/redirect_rob_idx only read under mispred) and idu_consume ----
out dec_bcast_mispred 1 @ bt.dec_bcast.mispred
out dec_bcast_br_mask 64 when dec_bcast_mispred @ bt.dec_bcast.br_mask
out dec_bcast_br_id 6 when dec_bcast_mispred @ bt.dec_bcast.br_id
out dec_bcast_redirect_rob_idx 7 when dec_bcast_mispred @ bt.dec_bcast.redirect_rob_idx
out dec_bcast_clear_mask 64 @ bt.dec_bcast.clear_mask
out idu_consume_fire 1 [8] @ bt.idu_consume.fire[i0]

# ---- outputs: br_latch (BackTop reads redirect_pc, PreIduQueue reads mispred/ftq_idx, both only under mispred) ----
out br_latch_mispred 1 @ bt.idu->br_latch.mispred
out br_latch_redirect_pc 32 when br_latch_mispred @ bt.idu->br_latch.redirect_pc
out br_latch_ftq_idx 6 when br_latch_mispred @ bt.idu->br_latch.ftq_idx
