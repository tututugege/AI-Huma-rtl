# PTAB (prediction table), 16 x 2152b, standalone 1R1W queue.  Same cycle semantics as fetch_addr_fifo (refetch = global_refetch);
# full = size>=15 (BPU back-pressure), empty = size==0 of the START of the cycle.
# predict_base_pc is stored ONCE (lane 0): front_ptab_write_comb (front_top.cpp:766) writes lane i = bpu pred_base_pc + 4*i,
# so lanes 1..7 are derived (checked on real traces with the one-off lane spec, see docs/modules/front_basic.md).
# need_mini_flush / dummy_entry are constant 0 in this configuration (frontend-boundary.md 3.4) and not in the entry.
module ptab
in  refetch 1 @ TTG_FT.global_refetch
in  rd_en   1 @ TTG_FT.ptab_read_enable
in  wr_en   1 @ TTG_FT.ptab_req.push_write_en
in  wr_predict_next_fetch_address 32 @ TTG_FT.ptab_req.push_write_entry.predict_next_fetch_address
in  wr_predict_dir 1 [8] @ TTG_FT.ptab_req.push_write_entry.predict_dir[i0]
in  wr_predict_base_pc 32 @ TTG_FT.ptab_req.push_write_entry.predict_base_pc[0]
in  wr_alt_pred 1 [8] @ TTG_FT.ptab_req.push_write_entry.alt_pred[i0]
in  wr_altpcpn 3 [8] @ TTG_FT.ptab_req.push_write_entry.altpcpn[i0]
in  wr_pcpn 3 [8] @ TTG_FT.ptab_req.push_write_entry.pcpn[i0]
in  wr_tage_idx 10 [8][4] @ TTG_FT.ptab_req.push_write_entry.tage_idx[i0][i1]
in  wr_tage_tag 8 [8][4] @ TTG_FT.ptab_req.push_write_entry.tage_tag[i0][i1]
out rd_valid 1 @ TTG_FT.ptab_req.pop_en
out rd_predict_next_fetch_address 32 when rd_valid @ TTG_FT.saved_ptab_out.predict_next_fetch_address
out rd_predict_dir 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.predict_dir[i0]
out rd_predict_base_pc 32 when rd_valid @ TTG_FT.saved_ptab_out.predict_base_pc[0]
out rd_alt_pred 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.alt_pred[i0]
out rd_altpcpn 3 [8] when rd_valid @ TTG_FT.saved_ptab_out.altpcpn[i0]
out rd_pcpn 3 [8] when rd_valid @ TTG_FT.saved_ptab_out.pcpn[i0]
out rd_tage_idx 10 [8][4] when rd_valid @ TTG_FT.saved_ptab_out.tage_idx[i0][i1]
out rd_tage_tag 8 [8][4] when rd_valid @ TTG_FT.saved_ptab_out.tage_tag[i0][i1]
out full  1 @ TTG_FT.full_q[2]
out empty 1 @ TTG_FT.empty_q[2]
