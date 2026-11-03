# AXI interconnect core (AXI_Interconnect.cpp, LLC-enabled live paths) one tick per record, 16 records per CPU cycle (scripts/lockstep_ticks_axi.sh).
# The LLC is OUTSIDE this module: its outputs (lo_*, hz_*) are inputs here, what the interconnect drives into it (li_*) are outputs.
# Master side = the per-tick values of read_ports[]/write_ports[] (b_* taps = comb_inputs time); the stale "a_*" values the C++ reads at comb_outputs
# time are NOT inputs: they are derived inside (DCache masters: previous tick's request, zero on tick 0; ICache: this tick's; others zero), see
# docs/modules/axi_interconnect.md section 3.  DDR side = sim_ddr (slave outputs sampled at comb_outputs time).  MMIO port: never active (DDR_BASE=0).
# Not in the spec: mode / mapped_offset / invalidate controls (constants), MMIO channels (tied off), AXI ID bits above 6, LLC mem-side ready consts.
module axi_ic

in  phase0 1 @ (TTG_MS.cur == 0)
# ---- masters ----
in  m_rd_valid 1 [4] @ TTG_AXI.t[TTG_MS.cur].b_rd[i0].valid
in  m_rd_addr 32 [4] @ TTG_AXI.t[TTG_MS.cur].b_rd[i0].addr
in  m_rd_size 8 [4] @ TTG_AXI.t[TTG_MS.cur].b_rd[i0].size
in  m_rd_id 4 [4] @ TTG_AXI.t[TTG_MS.cur].b_rd[i0].id
in  m_rd_bypass 1 [4] @ TTG_AXI.t[TTG_MS.cur].b_rd[i0].bypass
in  m_rd_resp_ready 1 [4] @ TTG_AXI.t[TTG_MS.cur].b_rd_resp_ready[i0]
in  m_wr_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr[i0].valid
in  m_wr_addr 32 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr[i0].addr
in  m_wr_data 512 [2] @w TTG_AXI.t[TTG_MS.cur].b_wr[i0].wdata
in  m_wr_strb 64 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr[i0].wstrb
in  m_wr_size 8 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr[i0].size
in  m_wr_id 4 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr[i0].id
in  m_wr_bypass 1 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr[i0].bypass
in  m_wr_resp_ready 1 [2] @ TTG_AXI.t[TTG_MS.cur].b_wr_resp_ready[i0]
# ---- DDR slave (sim_ddr) ----
in  d_arready 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.arready
in  d_rvalid 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.rvalid
in  d_rid 6 @ TTG_AXI.t[TTG_MS.cur].d_ddr.rid & 0x3f
in  d_rdata 256 @w TTG_AXI.t[TTG_MS.cur].d_ddr.rdata
in  d_rlast 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.rlast
in  d_awready 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.awready
in  d_wready 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.wready
in  d_bvalid 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.bvalid
in  d_bid 6 @ TTG_AXI.t[TTG_MS.cur].d_ddr.bid & 0x3f
in  d_bresp 2 @ TTG_AXI.t[TTG_MS.cur].d_ddr.bresp
# ---- LLC outputs (inputs here) ----
in  lo_rd_req_ready 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_req[i0].ready
in  lo_rd_resp_valid 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_resp[i0].valid
in  lo_rd_resp_id 4 [4] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_resp[i0].id
in  lo_rd_resp_data 512 [4] @w TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_resp[i0].data.words
in  lo_wr_req_ready 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_req[i0].ready
in  lo_wr_resp_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_resp[i0].valid
in  lo_wr_resp_id 4 [2] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_resp[i0].id
in  lo_wr_resp_resp 2 [2] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_resp[i0].resp
in  lo_mem_rd_req_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_valid
in  lo_mem_rd_req_addr 32 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_addr
in  lo_mem_rd_req_size 8 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_size
in  lo_mem_rd_req_id 4 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_id
in  lo_mem_wr_req_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_valid
in  lo_mem_wr_req_addr 32 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_addr
in  lo_mem_wr_req_data 512 @w TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_data.words
in  lo_mem_wr_req_strb 64 @ (uint64_t)TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_strobe
in  lo_mem_wr_req_size 8 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_size
in  lo_mem_wr_req_id 4 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_id
# hazard registers of the LLC
in  hz_lookup_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_valid
in  hz_lookup_is_write 1 @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_is_write
in  hz_lookup_addr 32 @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_addr
in  hz_lookup_master 2 @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_master
in  hz_lookup_id 4 @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_id
in  hz_rresp_fresh 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_regs.read_resp_fresh[i0]
in  hz_rresp_valid 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_regs.read_resp_valid[i0]
in  hz_rresp_id 4 [4] @ TTG_AXI.t[TTG_MS.cur].llc_regs.read_resp_id[i0]
in  hz_mshr_valid 1 [8] @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_valid[i0]
in  hz_mshr_is_write 1 [8] @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_is_write[i0]
in  hz_mshr_master 2 [8] @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_master[i0]
in  hz_mshr_id 4 [8] @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_id[i0]
in  hz_mshr_line 32 [8] @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_line_addr[i0]
in  hz_wctx_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_ctx_valid[i0]
in  hz_wctx_line 32 [2] @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_ctx_line_addr[i0]
in  hz_wresp_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_resp_valid[i0]
in  hz_wresp_line 32 [2] @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_resp_line_addr[i0]

# ==== outputs ====
# comb_outputs() results
out m_rd_resp_valid 1 [4] @ TTG_AXI.t[TTG_MS.cur].o1_rd_resp_valid[i0]
out m_rd_resp_id 4 [4] when m_rd_resp_valid @ TTG_AXI.t[TTG_MS.cur].o1_rd_resp_id[i0]
out m_rd_resp_data 512 [4] when m_rd_resp_valid @w TTG_AXI.t[TTG_MS.cur].o1_rd_resp_data[i0]
out m_rd_accepted 1 [4] @ TTG_AXI.t[TTG_MS.cur].o1_rd_accepted[i0]
out m_rd_accepted_id 4 [4] when m_rd_accepted @ TTG_AXI.t[TTG_MS.cur].o1_rd_accepted_id[i0]
out m_wr_accepted 1 [2] @ TTG_AXI.t[TTG_MS.cur].o1_wr_accepted[i0]
out m_wr_resp_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].o1_wr_resp_valid[i0]
out m_wr_resp_id 4 [2] when m_wr_resp_valid @ TTG_AXI.t[TTG_MS.cur].o1_wr_resp_id[i0]
out m_wr_resp_resp 2 [2] when m_wr_resp_valid @ TTG_AXI.t[TTG_MS.cur].o1_wr_resp_resp[i0]
out d_rready 1 @ TTG_AXI.t[TTG_MS.cur].o1_ddr_rready
out d_bready 1 @ TTG_AXI.t[TTG_MS.cur].o1_ddr_bready
# comb_inputs() results
out m_rd_req_ready 1 [4] @ TTG_AXI.t[TTG_MS.cur].o2_rd_req_ready[i0]
out m_wr_req_ready 1 [2] @ TTG_AXI.t[TTG_MS.cur].o2_wr_req_ready[i0]
out d_arvalid 1 @ TTG_AXI.t[TTG_MS.cur].o2_ddr.arvalid
out d_arid 6 when d_arvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.arid & 0x3f
out d_araddr 32 when d_arvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.araddr
out d_arlen 8 when d_arvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.arlen
out d_awvalid 1 @ TTG_AXI.t[TTG_MS.cur].o2_ddr.awvalid
out d_awid 6 when d_awvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.awid & 0x3f
out d_awaddr 32 when d_awvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.awaddr
out d_awlen 8 when d_awvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.awlen
out d_wvalid 1 @ TTG_AXI.t[TTG_MS.cur].o2_ddr.wvalid
out d_wdata 256 when d_wvalid @w TTG_AXI.t[TTG_MS.cur].o2_ddr.wdata
out d_wstrb 32 when d_wvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.wstrb
out d_wlast 1 when d_wvalid @ TTG_AXI.t[TTG_MS.cur].o2_ddr.wlast
# what the interconnect drives into the LLC (final comb_inputs() values)
out li_rd_valid 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].valid
out li_rd_addr 32 [4] when li_rd_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].addr
out li_rd_size 8 [4] when li_rd_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].total_size
out li_rd_id 4 [4] when li_rd_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].id
out li_rd_bypass 1 [4] when li_rd_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].bypass
out li_rd_resp_ready 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_resp[i0].ready
out li_wr_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].valid
out li_wr_addr 32 [2] when li_wr_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].addr
out li_wr_data 512 [2] when li_wr_valid @w TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].wdata.words
out li_wr_strb 64 [2] when li_wr_valid @ (uint64_t)TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].wstrb
out li_wr_size 8 [2] when li_wr_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].total_size
out li_wr_id 4 [2] when li_wr_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].id
out li_wr_bypass 1 [2] when li_wr_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].bypass
out li_wr_resp_ready 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_resp[i0].ready
out li_mem_rd_req_ready 1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_req_ready
out li_mem_rd_resp_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_resp_valid
out li_mem_rd_resp_data 512 when li_mem_rd_resp_valid @w TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_resp_data.words
out li_mem_rd_resp_id 4 when li_mem_rd_resp_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_resp_id
out li_mem_wr_req_ready 1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.write_req_ready
out li_mem_wr_resp_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.write_resp_valid
out li_mem_wr_resp 2 when li_mem_wr_resp_valid @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.write_resp
