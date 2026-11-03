# front_ctrl: the front-end control of front_top.cpp front_comb_calc (S1 global control, S2 read enables, S4 BPU gating,
# S5 fetch-addr write enable, S9 PTAB write enable, S10 flush decision, S11 front2back write/bypass, S14 output valid)
# plus the registered delayed predecode refetch (33 bit: predecode_refetch, predecode_refetch_address).
# The full/empty inputs are the FIFOs' start-of-cycle flags (functions of the FIFO size, see front_fifo).
# Not modelled: global_reset (front.in.reset is 1 only in FrontTop::init(); RTL uses rst_n) and constant-0 paths
# (frontend-boundary.md 3.4: slot1, mini flush, 2-ahead, the two bypasses that are compiled out, dummy PTAB entries).
module front_ctrl
in  be_refetch            1  @ cpu.front.in.refetch
in  be_refetch_address    32 @ cpu.front.in.refetch_address
in  be_fifo_read_enable   1  @ cpu.front.in.FIFO_read_enable
in  icache_ready          1  @ TTG_FT.icache_ready
in  fa_full               1  @ TTG_FT.full_q[0]
in  fa_empty              1  @ TTG_FT.empty_q[0]
in  inst_empty            1  @ TTG_FT.empty_q[1]
in  ptab_full             1  @ TTG_FT.full_q[2]
in  ptab_empty            1  @ TTG_FT.empty_q[2]
in  f2b_full              1  @ TTG_FT.full_q[3]
in  f2b_empty             1  @ TTG_FT.empty_q[3]
in  bpu_icache_read_valid 1  @ TTG_FT.bpu_out.icache_read_valid
in  bpu_ptab_write_enable 1  @ TTG_FT.bpu_out.PTAB_write_enable
in  checker_flush_enable  1  @ TTG_FT.checker_out.predecode_flush_enable
in  checker_flush_address 32 @ TTG_FT.checker_out.predict_next_fetch_address_corrected
out global_refetch        1  @ TTG_FT.global_refetch
out refetch_address       32 when global_refetch @ TTG_FT.refetch_address
out fa_rd_en              1  @ TTG_FT.fetch_addr_fifo_read_enable_slot0
out predecode_can_run     1  @ TTG_FT.predecode_can_run
out bpu_can_run           1  @ TTG_FT.bpu_can_run
out bpu_icache_read_ready 1  @ cpu.front.update_req_->bpu_seq_txn.inp.icache_read_ready
out fa_wr_en              1  @ TTG_FT.fetch_addr_req.push_en
out ptab_wr_en            1  @ TTG_FT.ptab_req.push_write_en
out f2b_wr_en             1  @ TTG_FT.front2back_req.push_en
out f2b_use_bypass        1  @ TTG_FT.use_front2back_output_bypass
out front_out_valid       1  @ cpu.front.out.FIFO_valid
out do_predecode_flush    1  @ TTG_FT.do_predecode_flush
