# AGU bank: 8 AguUnit instances (fu_idx 12..15 load, 16..19 store-address); identical logic. result = src1_rdata + imm.
module agu_bank

in  en 1 [8] @ bt.exu->units[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]]->in.en
in  consume 1 [8] @ bt.exu->units[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]]->in.consume
in  src1_rdata 32 [8] @ bt.exu->units[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]]->in.inst.src1_rdata
in  imm 32 [8] @ bt.exu->units[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]]->in.inst.imm

out complete 1 [8] @ bt.exu->in.fu2exu->entry[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]].complete
out ready 1 [8] @ bt.exu->in.fu2exu->entry[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]].ready
out result 32 [8] when complete @ bt.exu->in.fu2exu->entry[std::array<int,8>{12,13,14,15,16,17,18,19}[i0]].inst.result
