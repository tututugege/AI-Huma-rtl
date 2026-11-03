`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/AXI_Interconnect.cpp + AXI_LLC.cpp
// (+ the LLC tables of MemSubsystem.cpp AxiLlcTableRuntime)
// The whole AXI interconnect / LLC subsystem: axi_interconnect (core) + axi_llc (control + SRAM tables),
// wired port to port.
// Boundary = master ports and the DDR slave (spec/axi_subsys.io); DDR/MMIO models stay in the testbench.
module axi_subsys (
  input  logic clk,
  input  logic rst_n,
  input  logic phase0,
  input  logic m_rd_valid [4],
  input  logic [31:0] m_rd_addr [4],
  input  logic [7:0] m_rd_size [4],
  input  logic [3:0] m_rd_id [4],
  input  logic m_rd_bypass [4],
  input  logic m_rd_resp_ready [4],
  input  logic m_wr_valid [2],
  input  logic [31:0] m_wr_addr [2],
  input  logic [511:0] m_wr_data [2],
  input  logic [63:0] m_wr_strb [2],
  input  logic [7:0] m_wr_size [2],
  input  logic [3:0] m_wr_id [2],
  input  logic m_wr_bypass [2],
  input  logic m_wr_resp_ready [2],
  input  logic d_arready,
  input  logic d_rvalid,
  input  logic [5:0] d_rid,
  input  logic [255:0] d_rdata,
  input  logic d_awready,
  input  logic d_wready,
  input  logic d_bvalid,
  input  logic [5:0] d_bid,
  input  logic [1:0] d_bresp,
  output logic m_rd_resp_valid [4],
  output logic [3:0] m_rd_resp_id [4],
  output logic [511:0] m_rd_resp_data [4],
  output logic m_rd_accepted [4],
  output logic m_rd_acc_new [4],
  output logic [3:0] m_rd_acc_new_id [4],
  output logic m_wr_acc_new [2],
  output logic [3:0] m_rd_accepted_id [4],
  output logic m_wr_accepted [2],
  output logic m_wr_resp_valid [2],
  output logic [3:0] m_wr_resp_id [2],
  output logic [1:0] m_wr_resp_resp [2],
  output logic d_rready,
  output logic d_bready,
  output logic m_rd0_req_ready,
  output logic m_rd3_req_ready,
  output logic m_wr1_req_ready,
  output logic d_arvalid,
  output logic [5:0] d_arid,
  output logic [31:0] d_araddr,
  output logic [7:0] d_arlen,
  output logic d_awvalid,
  output logic [5:0] d_awid,
  output logic [31:0] d_awaddr,
  output logic [7:0] d_awlen,
  output logic d_wvalid,
  output logic [255:0] d_wdata,
  output logic [31:0] d_wstrb,
  output logic d_wlast
);
  logic up_rd_req_ready [4];
  logic up_rd_resp_valid [4];
  logic [3:0] up_rd_resp_id [4];
  logic [511:0] up_rd_resp_data [4];
  logic up_wr_req_ready [2];
  logic up_wr_resp_valid [2];
  logic [3:0] up_wr_resp_id [2];
  logic [1:0] up_wr_resp_resp [2];
  logic mem_rd_req_valid;
  logic [31:0] mem_rd_req_addr;
  logic [7:0] mem_rd_req_size;
  logic [3:0] mem_rd_req_id;
  logic mem_wr_req_valid;
  logic [31:0] mem_wr_req_addr;
  logic [511:0] mem_wr_req_data;
  logic [63:0] mem_wr_req_strb;
  logic [7:0] mem_wr_req_size;
  logic [3:0] mem_wr_req_id;
  logic hz_lookup_valid;
  logic hz_lookup_is_write;
  logic [31:0] hz_lookup_addr;
  logic [1:0] hz_lookup_master;
  logic [3:0] hz_lookup_id;
  logic hz_rresp_fresh [4];
  logic hz_rresp_valid [4];
  logic [3:0] hz_rresp_id [4];
  logic hz_mshr_valid [8];
  logic hz_mshr_is_write [8];
  logic [1:0] hz_mshr_master [8];
  logic [3:0] hz_mshr_id [8];
  logic [31:0] hz_mshr_line [8];
  logic up_rd_valid [4];
  logic [31:0] up_rd_addr [4];
  logic [7:0] up_rd_size [4];
  logic [3:0] up_rd_id [4];
  logic up_rd_bypass [4];
  logic up_rd_resp_ready [4];
  logic up_wr_valid [2];
  logic [31:0] up_wr_addr [2];
  logic [511:0] up_wr_data [2];
  logic [63:0] up_wr_strb [2];
  logic [7:0] up_wr_size [2];
  logic [3:0] up_wr_id [2];
  logic up_wr_bypass [2];
  logic up_wr_resp_ready [2];
  logic mem_rd_req_ready;
  logic mem_rd_resp_valid;
  logic [511:0] mem_rd_resp_data;
  logic [3:0] mem_rd_resp_id;
  logic mem_wr_req_ready;
  logic mem_wr_resp_valid;
  logic [1:0] mem_wr_resp;
  logic hz_wctx_valid [2];
  logic [31:0] hz_wctx_line [2];
  logic hz_wresp_valid [2];
  logic [31:0] hz_wresp_line [2];

  axi_interconnect u_ic (
    .clk, .rst_n,
    .phase0(phase0),
    .m_rd_valid(m_rd_valid),
    .m_rd_addr(m_rd_addr),
    .m_rd_size(m_rd_size),
    .m_rd_id(m_rd_id),
    .m_rd_bypass(m_rd_bypass),
    .m_rd_resp_ready(m_rd_resp_ready),
    .m_wr_valid(m_wr_valid),
    .m_wr_addr(m_wr_addr),
    .m_wr_data(m_wr_data),
    .m_wr_strb(m_wr_strb),
    .m_wr_size(m_wr_size),
    .m_wr_id(m_wr_id),
    .m_wr_bypass(m_wr_bypass),
    .m_wr_resp_ready(m_wr_resp_ready),
    .d_arready(d_arready),
    .d_rvalid(d_rvalid),
    .d_rid(d_rid),
    .d_rdata(d_rdata),
    .d_awready(d_awready),
    .d_wready(d_wready),
    .d_bvalid(d_bvalid),
    .d_bid(d_bid),
    .d_bresp(d_bresp),
    .lo_rd_req_ready(up_rd_req_ready),
    .lo_rd_resp_valid(up_rd_resp_valid),
    .lo_rd_resp_id(up_rd_resp_id),
    .lo_rd_resp_data(up_rd_resp_data),
    .lo_wr_req_ready(up_wr_req_ready),
    .lo_wr_resp_valid(up_wr_resp_valid),
    .lo_wr_resp_id(up_wr_resp_id),
    .lo_wr_resp_resp(up_wr_resp_resp),
    .lo_mem_rd_req_valid(mem_rd_req_valid),
    .lo_mem_rd_req_addr(mem_rd_req_addr),
    .lo_mem_rd_req_size(mem_rd_req_size),
    .lo_mem_rd_req_id(mem_rd_req_id),
    .lo_mem_wr_req_valid(mem_wr_req_valid),
    .lo_mem_wr_req_addr(mem_wr_req_addr),
    .lo_mem_wr_req_data(mem_wr_req_data),
    .lo_mem_wr_req_strb(mem_wr_req_strb),
    .lo_mem_wr_req_size(mem_wr_req_size),
    .lo_mem_wr_req_id(mem_wr_req_id),
    .hz_lookup_valid(hz_lookup_valid),
    .hz_lookup_is_write(hz_lookup_is_write),
    .hz_lookup_addr(hz_lookup_addr),
    .hz_lookup_master(hz_lookup_master),
    .hz_lookup_id(hz_lookup_id),
    .hz_rresp_fresh(hz_rresp_fresh),
    .hz_rresp_valid(hz_rresp_valid),
    .hz_rresp_id(hz_rresp_id),
    .hz_mshr_valid(hz_mshr_valid),
    .hz_mshr_is_write(hz_mshr_is_write),
    .hz_mshr_master(hz_mshr_master),
    .hz_mshr_id(hz_mshr_id),
    .hz_mshr_line(hz_mshr_line),
    .m_rd_resp_valid(m_rd_resp_valid),
    .m_rd_resp_id(m_rd_resp_id),
    .m_rd_resp_data(m_rd_resp_data),
    .m_rd_accepted(m_rd_accepted), .m_rd_acc_new, .m_rd_acc_new_id, .m_wr_acc_new,
    .m_rd_accepted_id(m_rd_accepted_id),
    .m_wr_accepted(m_wr_accepted),
    .m_wr_resp_valid(m_wr_resp_valid),
    .m_wr_resp_id(m_wr_resp_id),
    .m_wr_resp_resp(m_wr_resp_resp),
    .d_rready(d_rready),
    .d_bready(d_bready),
    .m_rd0_req_ready(m_rd0_req_ready),
    .m_rd3_req_ready(m_rd3_req_ready),
    .m_wr1_req_ready(m_wr1_req_ready),
    .d_arvalid(d_arvalid),
    .d_arid(d_arid),
    .d_araddr(d_araddr),
    .d_arlen(d_arlen),
    .d_awvalid(d_awvalid),
    .d_awid(d_awid),
    .d_awaddr(d_awaddr),
    .d_awlen(d_awlen),
    .d_wvalid(d_wvalid),
    .d_wdata(d_wdata),
    .d_wstrb(d_wstrb),
    .d_wlast(d_wlast),
    .li_rd_valid(up_rd_valid),
    .li_rd_addr(up_rd_addr),
    .li_rd_size(up_rd_size),
    .li_rd_id(up_rd_id),
    .li_rd_bypass(up_rd_bypass),
    .li_rd_resp_ready(up_rd_resp_ready),
    .li_wr_valid(up_wr_valid),
    .li_wr_addr(up_wr_addr),
    .li_wr_data(up_wr_data),
    .li_wr_strb(up_wr_strb),
    .li_wr_size(up_wr_size),
    .li_wr_id(up_wr_id),
    .li_wr_bypass(up_wr_bypass),
    .li_wr_resp_ready(up_wr_resp_ready),
    .li_mem_rd_req_ready(mem_rd_req_ready),
    .li_mem_rd_resp_valid(mem_rd_resp_valid),
    .li_mem_rd_resp_data(mem_rd_resp_data),
    .li_mem_rd_resp_id(mem_rd_resp_id),
    .li_mem_wr_req_ready(mem_wr_req_ready),
    .li_mem_wr_resp_valid(mem_wr_resp_valid),
    .li_mem_wr_resp(mem_wr_resp)
  );

  axi_llc u_llc (
    .clk, .rst_n,
    .up_rd_valid(up_rd_valid),
    .up_rd_addr(up_rd_addr),
    .up_rd_size(up_rd_size),
    .up_rd_id(up_rd_id),
    .up_rd_bypass(up_rd_bypass),
    .up_rd_resp_ready(up_rd_resp_ready),
    .up_wr_valid(up_wr_valid),
    .up_wr_addr(up_wr_addr),
    .up_wr_data(up_wr_data),
    .up_wr_strb(up_wr_strb),
    .up_wr_size(up_wr_size),
    .up_wr_id(up_wr_id),
    .up_wr_bypass(up_wr_bypass),
    .up_wr_resp_ready(up_wr_resp_ready),
    .mem_rd_req_ready(mem_rd_req_ready),
    .mem_rd_resp_valid(mem_rd_resp_valid),
    .mem_rd_resp_data(mem_rd_resp_data),
    .mem_rd_resp_id(mem_rd_resp_id),
    .mem_wr_req_ready(mem_wr_req_ready),
    .mem_wr_resp_valid(mem_wr_resp_valid),
    .mem_wr_resp(mem_wr_resp),
    .up_rd_req_ready(up_rd_req_ready),
    .up_rd_resp_valid(up_rd_resp_valid),
    .up_rd_resp_id(up_rd_resp_id),
    .up_rd_resp_data(up_rd_resp_data),
    .up_wr_req_ready(up_wr_req_ready),
    .up_wr_resp_valid(up_wr_resp_valid),
    .up_wr_resp_id(up_wr_resp_id),
    .up_wr_resp_resp(up_wr_resp_resp),
    .mem_rd_req_valid(mem_rd_req_valid),
    .mem_rd_req_addr(mem_rd_req_addr),
    .mem_rd_req_size(mem_rd_req_size),
    .mem_rd_req_id(mem_rd_req_id),
    .mem_wr_req_valid(mem_wr_req_valid),
    .mem_wr_req_addr(mem_wr_req_addr),
    .mem_wr_req_data(mem_wr_req_data),
    .mem_wr_req_strb(mem_wr_req_strb),
    .mem_wr_req_size(mem_wr_req_size),
    .mem_wr_req_id(mem_wr_req_id),
    .hz_lookup_valid(hz_lookup_valid),
    .hz_lookup_is_write(hz_lookup_is_write),
    .hz_lookup_addr(hz_lookup_addr),
    .hz_lookup_master(hz_lookup_master),
    .hz_lookup_id(hz_lookup_id),
    .hz_rresp_fresh(hz_rresp_fresh),
    .hz_rresp_valid(hz_rresp_valid),
    .hz_rresp_id(hz_rresp_id),
    .hz_mshr_valid(hz_mshr_valid),
    .hz_mshr_is_write(hz_mshr_is_write),
    .hz_mshr_master(hz_mshr_master),
    .hz_mshr_id(hz_mshr_id),
    .hz_mshr_line(hz_mshr_line),
    .hz_wctx_valid(hz_wctx_valid),
    .hz_wctx_line(hz_wctx_line),
    .hz_wresp_valid(hz_wresp_valid),
    .hz_wresp_line(hz_wresp_line)
  );
endmodule

`default_nettype wire
