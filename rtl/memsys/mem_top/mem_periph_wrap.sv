// Ref: rtl/memsys/mem_top/mem_top.sv (peripheral_axi vs external full 64-bit AXI4 MMIO wrapper)
`default_nettype none

// Selects between the simulation peripheral_axi path (EXT_MMIO_EN=0) and the real full 64-bit AXI4
// MMIO master port (EXT_MMIO_EN=1, used by chip_top) while preserving the registered hold boundary.
module mem_periph_wrap import ttg_cfg_pkg::*; import memcpu_pkg::*; #(
  parameter bit EXT_MMIO_EN = 1'b0
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 phase0,
  input  logic                 req_is_mmio,
  input  logic                 req_wen,
  input  logic [31:0]          req_addr,
  input  logic [XLEN_BITS-1:0] req_wdata,
  input  logic [2:0]           req_func3,
  input  logic                 env_modeled,
  input  logic [XLEN_BITS-1:0] env_rdata,
  input  logic                 ax_pa_rd_acc,
  input  logic                 ax_pa_rd_rv,
  input  logic [31:0]          ax_pa_rd_data,
  input  logic                 ax_pa_wr_acc,
  input  logic                 ax_pa_wr_rv,
  output logic                 pa_rd_valid,
  output logic [31:0]          pa_rd_addr,
  output logic [PA_SIZE_W-1:0] pa_rd_size,
  output logic                 pa_rd_resp_ready,
  output logic                 pa_wr_valid,
  output logic [31:0]          pa_wr_addr,
  output logic [PA_SIZE_W-1:0] pa_wr_size,
  output logic [3:0]           pa_wr_wstrb,
  output logic [31:0]          pa_wr_wdata,
  output logic                 pa_wr_resp_ready,
  output logic                 env_rd_en,
  output logic [31:0]          env_rd_addr,
  output logic [2:0]           env_rd_func3,
  output logic                 peripheral_resp_ready,
  output logic                 peripheral_resp_is_mmio,
  output logic [XLEN_BITS-1:0] peripheral_resp_mmio_rdata,
  // Full 64-bit AXI4 external MMIO master (active when EXT_MMIO_EN = 1)
  output logic                 mmio_arvalid,
  input  logic                 mmio_arready,
  output logic [3:0]           mmio_arid,
  output logic [31:0]          mmio_araddr,
  output logic [7:0]           mmio_arlen,
  output logic [2:0]           mmio_arsize,
  output logic [1:0]           mmio_arburst,
  output logic                 mmio_arlock,
  output logic [3:0]           mmio_arcache,
  output logic [2:0]           mmio_arprot,
  output logic [3:0]           mmio_arqos,
  output logic [3:0]           mmio_arregion,
  input  logic                 mmio_rvalid,
  output logic                 mmio_rready,
  input  logic [3:0]           mmio_rid,
  input  logic [63:0]          mmio_rdata,
  input  logic [1:0]           mmio_rresp,
  input  logic                 mmio_rlast,
  output logic                 mmio_awvalid,
  input  logic                 mmio_awready,
  output logic [3:0]           mmio_awid,
  output logic [31:0]          mmio_awaddr,
  output logic [7:0]           mmio_awlen,
  output logic [2:0]           mmio_awsize,
  output logic [1:0]           mmio_awburst,
  output logic                 mmio_awlock,
  output logic [3:0]           mmio_awcache,
  output logic [2:0]           mmio_awprot,
  output logic [3:0]           mmio_awqos,
  output logic [3:0]           mmio_awregion,
  output logic                 mmio_wvalid,
  input  logic                 mmio_wready,
  output logic [63:0]          mmio_wdata,
  output logic [7:0]           mmio_wstrb,
  output logic                 mmio_wlast,
  input  logic                 mmio_bvalid,
  output logic                 mmio_bready,
  input  logic [3:0]           mmio_bid,
  input  logic [1:0]           mmio_bresp
);

  logic                 pa_resp_ready, pa_resp_is_mmio;
  logic [XLEN_BITS-1:0] pa_resp_rdata;

  if (!EXT_MMIO_EN) begin : g_sim_periph
    peripheral_axi u_periph (
      .clk, .rst_n, .cpu_en(phase0),
      .req_is_mmio, .req_wen, .req_addr, .req_wdata, .req_func3,
      .env_modeled, .env_rdata,
      .axi_rd_req_accepted(ax_pa_rd_acc), .axi_rd_resp_valid(ax_pa_rd_rv), .axi_rd_resp_data(ax_pa_rd_data),
      .axi_wr_req_accepted(ax_pa_wr_acc), .axi_wr_resp_valid(ax_pa_wr_rv),
      .resp_ready(pa_resp_ready), .resp_is_mmio(pa_resp_is_mmio), .resp_rdata(pa_resp_rdata),
      .axi_rd_req_valid(pa_rd_valid), .axi_rd_req_addr(pa_rd_addr), .axi_rd_req_size(pa_rd_size),
      .axi_rd_resp_ready(pa_rd_resp_ready),
      .axi_wr_req_valid(pa_wr_valid), .axi_wr_req_addr(pa_wr_addr), .axi_wr_req_size(pa_wr_size),
      .axi_wr_req_wstrb(pa_wr_wstrb), .axi_wr_req_wdata(pa_wr_wdata), .axi_wr_resp_ready(pa_wr_resp_ready),
      .env_rd_en, .env_rd_addr, .env_rd_func3
    );
    assign mmio_arvalid  = 1'b0;
    assign mmio_arid     = 4'd0;
    assign mmio_araddr   = 32'd0;
    assign mmio_arlen    = 8'd0;
    assign mmio_arsize   = 3'd0;
    assign mmio_arburst  = 2'd0;
    assign mmio_arlock   = 1'b0;
    assign mmio_arcache  = 4'd0;
    assign mmio_arprot   = 3'd0;
    assign mmio_arqos    = 4'd0;
    assign mmio_arregion = 4'd0;
    assign mmio_rready   = 1'b0;
    assign mmio_awvalid  = 1'b0;
    assign mmio_awid     = 4'd0;
    assign mmio_awaddr   = 32'd0;
    assign mmio_awlen    = 8'd0;
    assign mmio_awsize   = 3'd0;
    assign mmio_awburst  = 2'd0;
    assign mmio_awlock   = 1'b0;
    assign mmio_awcache  = 4'd0;
    assign mmio_awprot   = 3'd0;
    assign mmio_awqos    = 4'd0;
    assign mmio_awregion = 4'd0;
    assign mmio_wvalid   = 1'b0;
    assign mmio_wdata    = 64'd0;
    assign mmio_wstrb    = 8'd0;
    assign mmio_wlast    = 1'b0;
    assign mmio_bready   = 1'b0;
    logic unused_ext;
    assign unused_ext = &{1'b0, mmio_arready, mmio_rvalid, mmio_rid, mmio_rdata, mmio_rresp, mmio_rlast,
                          mmio_awready, mmio_wready, mmio_bvalid, mmio_bid, mmio_bresp};
  end else begin : g_ext_mmio
    mem_mmio_axi u_mmio_axi (
      .clk, .rst_n, .cpu_en(phase0),
      .req_is_mmio, .req_wen, .req_addr, .req_wdata, .req_func3,
      .resp_ready(pa_resp_ready), .resp_is_mmio(pa_resp_is_mmio), .resp_rdata(pa_resp_rdata),
      .m_arvalid(mmio_arvalid), .m_arready(mmio_arready), .m_arid(mmio_arid), .m_araddr(mmio_araddr),
      .m_arlen(mmio_arlen), .m_arsize(mmio_arsize), .m_arburst(mmio_arburst), .m_arlock(mmio_arlock),
      .m_arcache(mmio_arcache), .m_arprot(mmio_arprot), .m_arqos(mmio_arqos), .m_arregion(mmio_arregion),
      .m_rvalid(mmio_rvalid), .m_rready(mmio_rready), .m_rid(mmio_rid), .m_rdata(mmio_rdata),
      .m_rresp(mmio_rresp), .m_rlast(mmio_rlast),
      .m_awvalid(mmio_awvalid), .m_awready(mmio_awready), .m_awid(mmio_awid), .m_awaddr(mmio_awaddr),
      .m_awlen(mmio_awlen), .m_awsize(mmio_awsize), .m_awburst(mmio_awburst), .m_awlock(mmio_awlock),
      .m_awcache(mmio_awcache), .m_awprot(mmio_awprot), .m_awqos(mmio_awqos), .m_awregion(mmio_awregion),
      .m_wvalid(mmio_wvalid), .m_wready(mmio_wready), .m_wdata(mmio_wdata), .m_wstrb(mmio_wstrb),
      .m_wlast(mmio_wlast),
      .m_bvalid(mmio_bvalid), .m_bready(mmio_bready), .m_bid(mmio_bid), .m_bresp(mmio_bresp)
    );
    assign pa_rd_valid      = 1'b0;
    assign pa_rd_addr       = 32'd0;
    assign pa_rd_size       = '0;
    assign pa_rd_resp_ready = 1'b0;
    assign pa_wr_valid      = 1'b0;
    assign pa_wr_addr       = 32'd0;
    assign pa_wr_size       = '0;
    assign pa_wr_wstrb      = 4'd0;
    assign pa_wr_wdata      = 32'd0;
    assign pa_wr_resp_ready = 1'b0;
    assign env_rd_en        = 1'b0;
    assign env_rd_addr      = 32'd0;
    assign env_rd_func3     = 3'd0;
    logic unused_sim;
    assign unused_sim = &{1'b0, env_modeled, env_rdata, ax_pa_rd_acc, ax_pa_rd_rv,
                          ax_pa_rd_data, ax_pa_wr_acc, ax_pa_wr_rv};
  end

  logic                 hold_ready_q, hold_is_mmio_q;
  logic [XLEN_BITS-1:0] hold_rdata_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hold_ready_q <= 1'b0; hold_is_mmio_q <= 1'b0; hold_rdata_q <= '0;
    end else if (phase0) begin
      hold_ready_q <= pa_resp_ready; hold_is_mmio_q <= pa_resp_is_mmio; hold_rdata_q <= pa_resp_rdata;
    end
  end
  assign peripheral_resp_ready      = hold_ready_q;
  assign peripheral_resp_is_mmio    = hold_is_mmio_q;
  assign peripheral_resp_mmio_rdata = hold_rdata_q;

endmodule

`default_nettype wire
