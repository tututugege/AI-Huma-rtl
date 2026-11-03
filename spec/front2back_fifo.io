# front2back_FIFO (32 x 2424b), standalone 1R1W queue.  Same cycle semantics as fetch_addr_fifo, but refetch = BACKEND refetch
# only (front.in.refetch), NOT the delayed predecode refetch.  full = size==32, empty = size==0 of the START of the cycle.
# The output bypass (front2back_read_enable & empty & write) is outside this module: then wr_en = 0 and rd_valid = 0 here.
# predict_base_pc is stored once (lane 0), lanes 1..7 = lane0 + 4*i (comes unchanged from the PTAB entry).
module front2back_fifo
in  refetch 1 @ cpu.front.in.refetch
in  rd_en   1 @ TTG_FT.front2back_read_enable
in  wr_en   1 @ TTG_FT.front2back_req.push_en
in  wr_fetch_group 32 [8] @ TTG_FT.front2back_req.push_entry.fetch_group[i0]
in  wr_page_fault_inst 1 [8] @ TTG_FT.front2back_req.push_entry.page_fault_inst[i0]
in  wr_inst_valid 1 [8] @ TTG_FT.front2back_req.push_entry.inst_valid[i0]
in  wr_predict_dir_corrected 1 [8] @ TTG_FT.front2back_req.push_entry.predict_dir_corrected[i0]
in  wr_predict_base_pc 32 @ TTG_FT.front2back_req.push_entry.predict_base_pc[0]
in  wr_alt_pred 1 [8] @ TTG_FT.front2back_req.push_entry.alt_pred[i0]
in  wr_altpcpn 3 [8] @ TTG_FT.front2back_req.push_entry.altpcpn[i0]
in  wr_pcpn 3 [8] @ TTG_FT.front2back_req.push_entry.pcpn[i0]
in  wr_tage_idx 10 [8] [4] @ TTG_FT.front2back_req.push_entry.tage_idx[i0][i1]
in  wr_tage_tag 8 [8] [4] @ TTG_FT.front2back_req.push_entry.tage_tag[i0][i1]
in  wr_sc_used 1 [8] @ TTG_FT.front2back_req.push_entry.sc_used[i0]
in  wr_sc_pred 1 [8] @ TTG_FT.front2back_req.push_entry.sc_pred[i0]
in  wr_sc_sum 16 [8] @ TTG_FT.front2back_req.push_entry.sc_sum[i0]
in  wr_sc_idx 16 [8] [8] @ TTG_FT.front2back_req.push_entry.sc_idx[i0][i1]
in  wr_loop_used 1 [8] @ TTG_FT.front2back_req.push_entry.loop_used[i0]
in  wr_loop_hit 1 [8] @ TTG_FT.front2back_req.push_entry.loop_hit[i0]
in  wr_loop_pred 1 [8] @ TTG_FT.front2back_req.push_entry.loop_pred[i0]
in  wr_loop_idx 16 [8] @ TTG_FT.front2back_req.push_entry.loop_idx[i0]
in  wr_loop_tag 16 [8] @ TTG_FT.front2back_req.push_entry.loop_tag[i0]
in  wr_predict_next_fetch_address_corrected 32 @ TTG_FT.front2back_req.push_entry.predict_next_fetch_address_corrected
out rd_valid 1 @ TTG_FT.front2back_req.pop_en
out rd_fetch_group 32 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.fetch_group[i0]
out rd_page_fault_inst 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.page_fault_inst[i0]
out rd_inst_valid 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.inst_valid[i0]
out rd_predict_dir_corrected 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.predict_dir_corrected[i0]
out rd_predict_base_pc 32 when rd_valid @ TTG_FT.saved_front2back_fifo_out.predict_base_pc[0]
out rd_alt_pred 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.alt_pred[i0]
out rd_altpcpn 3 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.altpcpn[i0]
out rd_pcpn 3 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.pcpn[i0]
out rd_tage_idx 10 [8] [4] when rd_valid @ TTG_FT.saved_front2back_fifo_out.tage_idx[i0][i1]
out rd_tage_tag 8 [8] [4] when rd_valid @ TTG_FT.saved_front2back_fifo_out.tage_tag[i0][i1]
out rd_sc_used 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.sc_used[i0]
out rd_sc_pred 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.sc_pred[i0]
out rd_sc_sum 16 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.sc_sum[i0]
out rd_sc_idx 16 [8] [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.sc_idx[i0][i1]
out rd_loop_used 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.loop_used[i0]
out rd_loop_hit 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.loop_hit[i0]
out rd_loop_pred 1 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.loop_pred[i0]
out rd_loop_idx 16 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.loop_idx[i0]
out rd_loop_tag 16 [8] when rd_valid @ TTG_FT.saved_front2back_fifo_out.loop_tag[i0]
out rd_predict_next_fetch_address_corrected 32 when rd_valid @ TTG_FT.saved_front2back_fifo_out.predict_next_fetch_address_corrected
out full  1 @ TTG_FT.full_q[3]
out empty 1 @ TTG_FT.empty_q[3]
