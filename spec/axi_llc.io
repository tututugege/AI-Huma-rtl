# AXI LLC (AXI_LLC.cpp, tables from MemSubsystem.cpp AxiLlcTableRuntime) one tick per record, 16 records per CPU cycle (scripts/lockstep_ticks_axi.sh).
# Boundary = AXI_LLC.io.ext_in / ext_out of the FINAL llc.comb() of the tick (the one whose reg_write becomes the next state; the first
# comb() of comb_outputs() produces the same ext_out except in CPU cycle 1, docs/modules/axi_llc.md).  The four SRAM tables live INSIDE the RTL.
# Not in the spec (dead / constant in the default config, see docs/modules/axi_llc.md): invalidate_*, prefetch_*, direct_mapped, mode2_ddr_aligned,
# read_resp_ready / write_resp_ready of the mem side (constant 1).  Extra "hz_*" outputs = LLC registers the interconnect reads directly (hazard checks).
module axi_llc

# ---- upstream (from the interconnect core stage / master side) ----
in  up_rd_valid   1   [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].valid
in  up_rd_addr    32  [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].addr
in  up_rd_size    8   [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].total_size
in  up_rd_id      4   [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].id
in  up_rd_bypass  1   [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_req[i0].bypass
in  up_rd_resp_ready 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.read_resp[i0].ready
in  up_wr_valid   1   [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].valid
in  up_wr_addr    32  [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].addr
in  up_wr_data    512 [2] @w TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].wdata.words
in  up_wr_strb    64  [2] @ (uint64_t)TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].wstrb
in  up_wr_size    8   [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].total_size
in  up_wr_id      4   [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].id
in  up_wr_bypass  1   [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_req[i0].bypass
in  up_wr_resp_ready 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_in2.upstream.write_resp[i0].ready
# ---- memory side (from the interconnect AR/AW/R/B machinery) ----
in  mem_rd_req_ready  1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_req_ready
in  mem_rd_resp_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_resp_valid
in  mem_rd_resp_data  512 @w TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_resp_data.words
in  mem_rd_resp_id    4 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.read_resp_id
in  mem_wr_req_ready  1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.write_req_ready
in  mem_wr_resp_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.write_resp_valid
in  mem_wr_resp       2 @ TTG_AXI.t[TTG_MS.cur].llc_in2.mem.write_resp

# ---- outputs: upstream ----
out up_rd_req_ready 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_req[i0].ready
out up_rd_resp_valid 1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_resp[i0].valid
out up_rd_resp_id   4 [4] when up_rd_resp_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_resp[i0].id
out up_rd_resp_data 512 [4] when up_rd_resp_valid @w TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.read_resp[i0].data.words
out up_wr_req_ready 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_req[i0].ready
out up_wr_resp_valid 1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_resp[i0].valid
out up_wr_resp_id   4 [2] when up_wr_resp_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_resp[i0].id
out up_wr_resp_resp 2 [2] when up_wr_resp_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.upstream.write_resp[i0].resp
# ---- outputs: memory side ----
out mem_rd_req_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_valid
out mem_rd_req_addr 32 when mem_rd_req_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_addr
out mem_rd_req_size 8 when mem_rd_req_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_size
out mem_rd_req_id   4 when mem_rd_req_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.read_req_id
out mem_wr_req_valid 1 @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_valid
out mem_wr_req_addr 32 when mem_wr_req_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_addr
out mem_wr_req_data 512 when mem_wr_req_valid @w TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_data.words
out mem_wr_req_strb 64 when mem_wr_req_valid @ (uint64_t)TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_strobe
out mem_wr_req_size 8 when mem_wr_req_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_size
out mem_wr_req_id   4 when mem_wr_req_valid @ TTG_AXI.t[TTG_MS.cur].llc_out2.mem.write_req_id
# ---- outputs: registers read by the interconnect (hazard / id-conflict checks) ----
out hz_lookup_valid   1  @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_valid
out hz_lookup_is_write 1  when hz_lookup_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_is_write
out hz_lookup_addr    32 when hz_lookup_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_addr
out hz_lookup_master  2  when hz_lookup_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_master
out hz_lookup_id      4  when hz_lookup_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.lookup_id
out hz_rresp_fresh    1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_regs.read_resp_fresh[i0]
out hz_rresp_valid    1 [4] @ TTG_AXI.t[TTG_MS.cur].llc_regs.read_resp_valid[i0]
out hz_rresp_id       4 [4] when hz_rresp_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.read_resp_id[i0]
out hz_mshr_valid     1 [8] @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_valid[i0]
out hz_mshr_is_write  1 [8] when hz_mshr_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_is_write[i0]
out hz_mshr_master    2 [8] when hz_mshr_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_master[i0]
out hz_mshr_id        4 [8] when hz_mshr_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_id[i0]
out hz_mshr_line      32 [8] when hz_mshr_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.mshr_line_addr[i0]
out hz_wctx_valid     1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_ctx_valid[i0]
out hz_wctx_line      32 [2] when hz_wctx_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_ctx_line_addr[i0]
out hz_wresp_valid    1 [2] @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_resp_valid[i0]
out hz_wresp_line     32 [2] when hz_wresp_valid @ TTG_AXI.t[TTG_MS.cur].llc_regs.write_resp_line_addr[i0]
