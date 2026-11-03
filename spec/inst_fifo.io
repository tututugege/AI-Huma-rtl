# instruction_FIFO (16 x 576b; the 8 x pc[] of the C++ entry are debug-only and not stored), standalone 1R1W queue.
# Same cycle semantics as fetch_addr_fifo.  full = size==16 (structurally unreachable), empty = size==0.
# refetch = global_refetch.
module inst_fifo
in  refetch 1 @ TTG_FT.global_refetch
in  rd_en   1 @ TTG_FT.inst_fifo_read_enable
in  wr_en   1 @ TTG_FT.inst_req.push_en
in  wr_instructions 32 [8] @ TTG_FT.inst_req.push_entry.instructions[i0]
in  wr_page_fault_inst 1 [8] @ TTG_FT.inst_req.push_entry.page_fault_inst[i0]
in  wr_inst_valid 1 [8] @ TTG_FT.inst_req.push_entry.inst_valid[i0]
in  wr_predecode_type 2 [8] @ TTG_FT.inst_req.push_entry.predecode_type[i0]
in  wr_predecode_target_address 32 [8] @ TTG_FT.inst_req.push_entry.predecode_target_address[i0]
in  wr_seq_next_pc 32 @ TTG_FT.inst_req.push_entry.seq_next_pc
out rd_valid 1 @ TTG_FT.inst_req.pop_en
out rd_instructions 32 [8] when rd_valid @ TTG_FT.saved_fifo_out.instructions[i0]
out rd_page_fault_inst 1 [8] when rd_valid @ TTG_FT.saved_fifo_out.page_fault_inst[i0]
out rd_inst_valid 1 [8] when rd_valid @ TTG_FT.saved_fifo_out.inst_valid[i0]
out rd_predecode_type 2 [8] when rd_valid @ TTG_FT.saved_fifo_out.predecode_type[i0]
out rd_predecode_target_address 32 [8] when rd_valid @ TTG_FT.saved_fifo_out.predecode_target_address[i0]
out rd_seq_next_pc 32 when rd_valid @ TTG_FT.saved_fifo_out.seq_next_pc
out full  1 @ TTG_FT.full_q[1]
out empty 1 @ TTG_FT.empty_q[1]
