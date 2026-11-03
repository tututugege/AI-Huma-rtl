# PTAB (predict-info table) as a standalone 1R1W FIFO, recorded from the integrated front-end.
# Needs the front tap (docs/analysis/frontend-record-hook.md).  16 entries, flush on reset/refetch.
# Semantics of one cycle: (clear if reset|refetch) -> pop head if rd_en and queue non-empty (rd_valid)
#                         -> push wr_* if wr_en.  The head is read BEFORE this cycle's write; there is no
#                         empty-queue write-through (never exercised, see frontend-boundary.md 3.3).
module ptab
in  reset   1 @ TTG_FT.global_reset
in  refetch 1 @ TTG_FT.global_refetch
# rd_en = stage-3 read | icache->predecode bypass read (the latter is compiled out: constant 0 in this config)
in  rd_en   1 @ (TTG_FT.ptab_read_enable || TTG_FT.can_bypass_icache_to_predecode)
in  wr_en   1 @ TTG_FT.ptab_req.push_write_en
in  wr_predict_next_fetch_address 32 @ TTG_FT.ptab_req.push_write_entry.predict_next_fetch_address
in  wr_predict_dir 1 [8] @ TTG_FT.ptab_req.push_write_entry.predict_dir[i0]
in  wr_predict_base_pc 32 [8] @ TTG_FT.ptab_req.push_write_entry.predict_base_pc[i0]
in  wr_alt_pred 1 [8] @ TTG_FT.ptab_req.push_write_entry.alt_pred[i0]
in  wr_altpcpn 3 [8] @ TTG_FT.ptab_req.push_write_entry.altpcpn[i0]
in  wr_pcpn 3 [8] @ TTG_FT.ptab_req.push_write_entry.pcpn[i0]
in  wr_tage_idx 10 [8][4] @ TTG_FT.ptab_req.push_write_entry.tage_idx[i0][i1]
in  wr_tage_tag 8 [8][4] @ TTG_FT.ptab_req.push_write_entry.tage_tag[i0][i1]
in  wr_sc_used 1 [8] @ TTG_FT.ptab_req.push_write_entry.sc_used[i0]
in  wr_sc_pred 1 [8] @ TTG_FT.ptab_req.push_write_entry.sc_pred[i0]
in  wr_sc_sum 16 [8] @ TTG_FT.ptab_req.push_write_entry.sc_sum[i0]
in  wr_sc_idx 16 [8][8] @ TTG_FT.ptab_req.push_write_entry.sc_idx[i0][i1]
in  wr_loop_used 1 [8] @ TTG_FT.ptab_req.push_write_entry.loop_used[i0]
in  wr_loop_hit 1 [8] @ TTG_FT.ptab_req.push_write_entry.loop_hit[i0]
in  wr_loop_pred 1 [8] @ TTG_FT.ptab_req.push_write_entry.loop_pred[i0]
in  wr_loop_idx 16 [8] @ TTG_FT.ptab_req.push_write_entry.loop_idx[i0]
in  wr_loop_tag 16 [8] @ TTG_FT.ptab_req.push_write_entry.loop_tag[i0]
# ---- outputs ----
out rd_valid 1 @ TTG_FT.ptab_req.pop_en
out rd_predict_next_fetch_address 32 when rd_valid @ TTG_FT.saved_ptab_out.predict_next_fetch_address
out rd_predict_dir 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.predict_dir[i0]
out rd_predict_base_pc 32 [8] when rd_valid @ TTG_FT.saved_ptab_out.predict_base_pc[i0]
out rd_alt_pred 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.alt_pred[i0]
out rd_altpcpn 3 [8] when rd_valid @ TTG_FT.saved_ptab_out.altpcpn[i0]
out rd_pcpn 3 [8] when rd_valid @ TTG_FT.saved_ptab_out.pcpn[i0]
out rd_tage_idx 10 [8][4] when rd_valid @ TTG_FT.saved_ptab_out.tage_idx[i0][i1]
out rd_tage_tag 8 [8][4] when rd_valid @ TTG_FT.saved_ptab_out.tage_tag[i0][i1]
out rd_sc_used 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.sc_used[i0]
out rd_sc_pred 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.sc_pred[i0]
out rd_sc_sum 16 [8] when rd_valid @ TTG_FT.saved_ptab_out.sc_sum[i0]
out rd_sc_idx 16 [8][8] when rd_valid @ TTG_FT.saved_ptab_out.sc_idx[i0][i1]
out rd_loop_used 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.loop_used[i0]
out rd_loop_hit 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.loop_hit[i0]
out rd_loop_pred 1 [8] when rd_valid @ TTG_FT.saved_ptab_out.loop_pred[i0]
out rd_loop_idx 16 [8] when rd_valid @ TTG_FT.saved_ptab_out.loop_idx[i0]
out rd_loop_tag 16 [8] when rd_valid @ TTG_FT.saved_ptab_out.loop_tag[i0]
# registered flags the top level consumes: full = size >= PTAB_SIZE-1, empty = size == 0 (function of size_q)
out full  1 @ TTG_FT.full_q[2]
out empty 1 @ TTG_FT.empty_q[2]
