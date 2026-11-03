# Fpu (back-end/Exu/include/FPU.h class FPUSoftfloat, over IterativeFU in AbstractFU.h): the one FP functional unit,
# fu_idx 5 of Exu::units (issue port 1, after DIV(3) and ALU(4)). Boundary = AbstractFU::FuInput / FuOutput after
# BackTop::comb(): `in` is the final input (en/consume/flush/masks/inst), `out` is the final output (ready after consume).
# Inputs omitted on purpose: every ExuInst field the FU does not read (pc, ftq_*, src*_preg, src*_en, csr_idx, stq_*, ldq_idx,
#   br_id, ...) and `op` (always UOP_FP: the port only routes OP_MASK_FP uops to this FU; the default branch of
#   impl_compute for other ops is dead). imm is only read as `imm & 0x1F` (rs2 selector): 0 = signed, 1 = unsigned, anything
#   else is an assert(0) in the reference (unreachable), so only imm[0] is an input.
# Outputs: Exu reads out.inst only when out.complete (Exu.cpp comb_fu2exu_collect); of the inst only result, br_mask,
#   dest_preg, dest_en (-> PRF write-back / bypass) and rob_idx (-> ROB) are consumed for an FP uop; diag_val/mispred/br_taken/
#   page_fault_inst/flush_pipe stay at their ExuInst defaults (0) and `op` is UOP_FP. fflags are not modelled: nothing reads them.
module fpu

# ---- inputs (FuInput) ----
in  in_en 1 @ bt.exu->units[5]->in.en
in  in_consume 1 @ bt.exu->units[5]->in.consume
in  in_flush 1 @ bt.exu->units[5]->in.flush
in  in_flush_mask 64 @ bt.exu->units[5]->in.flush_mask
in  in_clear_mask 64 @ bt.exu->units[5]->in.clear_mask
in  in_inst_func3 3 @ bt.exu->units[5]->in.inst.func3
in  in_inst_func7 7 @ bt.exu->units[5]->in.inst.func7
in  in_inst_imm_rs2_bit0 1 @ (bt.exu->units[5]->in.inst.imm & 1)
in  in_inst_src1_rdata 32 @ bt.exu->units[5]->in.inst.src1_rdata
in  in_inst_src2_rdata 32 @ bt.exu->units[5]->in.inst.src2_rdata
in  in_inst_br_mask 64 @ bt.exu->units[5]->in.inst.br_mask
in  in_inst_dest_preg 7 @ bt.exu->units[5]->in.inst.dest_preg
in  in_inst_dest_en 1 @ bt.exu->units[5]->in.inst.dest_en
in  in_inst_rob_idx 7 @ bt.exu->units[5]->in.inst.rob_idx

# ---- outputs (FuOutput) ----
out out_ready 1 @ bt.exu->in.fu2exu->entry[5].ready
out out_complete 1 @ bt.exu->in.fu2exu->entry[5].complete
out out_inst_result 32 when out_complete @ bt.exu->in.fu2exu->entry[5].inst.result
out out_inst_br_mask 64 when out_complete @ bt.exu->in.fu2exu->entry[5].inst.br_mask
out out_inst_dest_preg 7 when out_complete @ bt.exu->in.fu2exu->entry[5].inst.dest_preg
out out_inst_dest_en 1 when out_complete @ bt.exu->in.fu2exu->entry[5].inst.dest_en
out out_inst_rob_idx 7 when out_complete @ bt.exu->in.fu2exu->entry[5].inst.rob_idx
