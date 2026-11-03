# AXI subsystem = axi_interconnect core + axi_llc (tables inside) -- the whole AXI interconnect / LLC of the reference, one tick per record,
# 16 records per CPU cycle (scripts/lockstep_ticks_axi.sh axi_subsys).  Boundary = masters (read_ports/write_ports) and the DDR slave;
# the LLC boundary signals (lo_*/li_*/hz_*) of spec/axi_interconnect.io are internal here.  See docs/modules/axi_interconnect.md.
module axi_subsys

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
in  d_awready 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.awready
in  d_wready 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.wready
in  d_bvalid 1 @ TTG_AXI.t[TTG_MS.cur].d_ddr.bvalid
in  d_bid 6 @ TTG_AXI.t[TTG_MS.cur].d_ddr.bid & 0x3f
in  d_bresp 2 @ TTG_AXI.t[TTG_MS.cur].d_ddr.bresp

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
# req.ready: only the ICache (0) and peripheral (3) read ports and the peripheral write port (1) are consumed (DCache ignores it)
out m_rd0_req_ready 1 @ TTG_AXI.t[TTG_MS.cur].o2_rd_req_ready[0]
out m_rd3_req_ready 1 @ TTG_AXI.t[TTG_MS.cur].o2_rd_req_ready[3]
out m_wr1_req_ready 1 @ TTG_AXI.t[TTG_MS.cur].o2_wr_req_ready[1]
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

