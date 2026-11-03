# MUL bank: 2 MulUnit (FixedLatencyFU lat=2) instances (fu_idx 0,6). func3 low 2 bits only (mul/mulh/mulhsu/mulhu). op is constant UOP_MUL.
# Payload = the ExuInst fields consumers read for a MUL (rob_idx, dest_preg, dest_en, br_mask); diag_val/mispred/... are always 0.
# Outputs done_* = payload of the finished uop (br_mask has clear_mask applied while it waited).
module mul_bank

in  en 1 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.en
in  consume 1 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.consume
in  flush 1 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.flush
in  flush_mask 64 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.flush_mask
in  clear_mask 64 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.clear_mask
in  func3 2 [2] @ (bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.func3 & 3)
in  src1_rdata 32 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.src1_rdata
in  src2_rdata 32 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.src2_rdata
in  rob_idx 7 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.rob_idx
in  dest_preg 7 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.dest_preg
in  dest_en 1 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.dest_en
in  br_mask 64 [2] @ bt.exu->units[std::array<int,2>{0,6}[i0]]->in.inst.br_mask

out complete 1 [2] @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].complete
out ready 1 [2] @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].ready
out result 32 [2] when complete @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].inst.result
out done_rob_idx 7 [2] when complete @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].inst.rob_idx
out done_dest_preg 7 [2] when complete @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].inst.dest_preg
out done_dest_en 1 [2] when complete @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].inst.dest_en
out done_br_mask 64 [2] when complete @ bt.exu->in.fu2exu->entry[std::array<int,2>{0,6}[i0]].inst.br_mask
