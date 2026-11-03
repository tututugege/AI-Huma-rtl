# SDU bank: 4 SduUnit instances (fu_idx 20..23). amo_op = func7[6:2] (only bits the unit reads).
module sdu_bank

in  en 1 [4] @ bt.exu->units[std::array<int,4>{20,21,22,23}[i0]]->in.en
in  consume 1 [4] @ bt.exu->units[std::array<int,4>{20,21,22,23}[i0]]->in.consume
in  is_atomic 1 [4] @ bt.exu->units[std::array<int,4>{20,21,22,23}[i0]]->in.inst.is_atomic
in  amo_op 5 [4] @ (bt.exu->units[std::array<int,4>{20,21,22,23}[i0]]->in.inst.func7 >> 2)
in  src1_rdata 32 [4] @ bt.exu->units[std::array<int,4>{20,21,22,23}[i0]]->in.inst.src1_rdata
in  src2_rdata 32 [4] @ bt.exu->units[std::array<int,4>{20,21,22,23}[i0]]->in.inst.src2_rdata

out complete 1 [4] @ bt.exu->in.fu2exu->entry[std::array<int,4>{20,21,22,23}[i0]].complete
out ready 1 [4] @ bt.exu->in.fu2exu->entry[std::array<int,4>{20,21,22,23}[i0]].ready
out result 32 [4] when complete @ bt.exu->in.fu2exu->entry[std::array<int,4>{20,21,22,23}[i0]].inst.result
