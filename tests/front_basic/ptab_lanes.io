# one-off check spec (no RTL): is predict_base_pc[i] == predict_base_pc[0] + 4*i in every PTAB / front2back entry,
# on the write side and on the read side?  Checked by tests/front_basic/check_lanes.py.
module ptab_lanes
in  ptab_we  1 @ TTG_FT.ptab_req.push_write_en
in  ptab_wpc 32 [8] @ TTG_FT.ptab_req.push_write_entry.predict_base_pc[i0]
in  ptab_rv  1 @ TTG_FT.ptab_req.pop_en
in  ptab_rpc 32 [8] @ TTG_FT.saved_ptab_out.predict_base_pc[i0]
in  f2b_we   1 @ TTG_FT.front2back_req.push_en
in  f2b_wpc  32 [8] @ TTG_FT.front2back_req.push_entry.predict_base_pc[i0]
in  f2b_rv   1 @ TTG_FT.front2back_req.pop_en
in  f2b_rpc  32 [8] @ TTG_FT.saved_front2back_fifo_out.predict_base_pc[i0]
in  out_valid 1 @ cpu.front.out.FIFO_valid
in  out_pc   32 [8] @ cpu.front.out.pc[i0]
out dummy    1 @ 0
