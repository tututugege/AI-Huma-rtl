# BRU bank: 4 BruUnit instances (fu_idx 24..27). result of a BRU is always 0 (never written by C++, ExuInst.result starts at 0).
module bru_bank

in  en 1 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.en
in  consume 1 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.consume
in  op 5 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.op
in  func3 3 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.func3
in  src1_en 1 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.src1_en
in  src1_rdata 32 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.src1_rdata
in  src2_rdata 32 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.src2_rdata
in  pc 32 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.pc
in  imm 32 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.imm
in  ftq_pred_taken 1 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.ftq_pred_taken
in  ftq_next_pc 32 [4] @ bt.exu->units[std::array<int,4>{24,25,26,27}[i0]]->in.inst.ftq_next_pc

out complete 1 [4] @ bt.exu->in.fu2exu->entry[std::array<int,4>{24,25,26,27}[i0]].complete
out ready 1 [4] @ bt.exu->in.fu2exu->entry[std::array<int,4>{24,25,26,27}[i0]].ready
out br_taken 1 [4] when complete @ bt.exu->in.fu2exu->entry[std::array<int,4>{24,25,26,27}[i0]].inst.br_taken
out mispred 1 [4] when complete @ bt.exu->in.fu2exu->entry[std::array<int,4>{24,25,26,27}[i0]].inst.mispred
out diag_val 32 [4] when complete @ bt.exu->in.fu2exu->entry[std::array<int,4>{24,25,26,27}[i0]].inst.diag_val
