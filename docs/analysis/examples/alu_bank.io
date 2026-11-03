# ALU bank (6 AluUnit instances, FU indices 1,4,7,9,10,11) recorded at the FuInput/FuOutput boundary.
# Needs NO simulator patch: after BackTop::comb() every unit still holds its final `in` and `out`.
# Only the fields AluUnit::impl_compute reads are inputs; the pass-through fields of ExuInst (rob_idx, dest_preg,
# br_mask, ...) are verified at the Exu top level, not here.  `result` is compared only when en (complete == en).
module alu_bank
in  en 1 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.en
in  op 5 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.op
in  func3 3 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.func3
in  func7 7 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.func7
in  src1_is_pc 1 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.src1_is_pc
in  src2_is_imm 1 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.src2_is_imm
in  pc 32 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.pc
in  imm 32 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.imm
in  src1_rdata 32 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.src1_rdata
in  src2_rdata 32 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.src2_rdata
out complete 1 [6] @ bt.exu->in.fu2exu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].complete
out result 32 [6] when complete @ bt.exu->in.fu2exu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.result
