# ALU bank: 6 AluUnit instances (fu_idx 1,4,7,9,10,11) at the FuInput/FuOutput boundary (see docs/modules/exu_int.md).
# Inputs: only what AluUnit::impl_compute reads (+ en/consume for the handshake). Pass-through uop fields are checked at Exu level.
# result: unwritten-by-C++ branches leave it at the incoming ExuInst.result (0); compared strictly whenever complete.
module alu_bank

in  en 1 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.en
in  consume 1 [6] @ bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.consume
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
out ready 1 [6] @ bt.exu->in.fu2exu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].ready
out result 32 [6] when complete @ bt.exu->in.fu2exu->entry[std::array<int,6>{1,4,7,9,10,11}[i0]].inst.result
