// Ref: docs/modules/soc_axi.md  Full 5-channel AXI4 register slice (timing boundary isolation)
`default_nettype none

// Isolates all 5 AXI4 channels (AR, R, AW, W, B) with full-throughput skid buffers.
// Breaks forward valid/payload and backward ready combinational paths at module/chip boundaries.
module soc_axi_reg_slice #(
  parameter int DATA_W = 64,
  parameter int ADDR_W = 32,
  parameter int ID_W   = 6
) (
  input  logic                clk,
  input  logic                rst_n,
  // Slave (upstream) side
  input  logic                s_arvalid,
  output logic                s_arready,
  input  logic [ID_W-1:0]     s_arid,
  input  logic [ADDR_W-1:0]   s_araddr,
  input  logic [7:0]          s_arlen,
  input  logic [2:0]          s_arsize,
  input  logic [1:0]          s_arburst,
  input  logic                s_arlock,
  input  logic [3:0]          s_arcache,
  input  logic [2:0]          s_arprot,
  input  logic [3:0]          s_arqos,
  input  logic [3:0]          s_arregion,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic [ID_W-1:0]     s_rid,
  output logic [DATA_W-1:0]   s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,
  input  logic                s_awvalid,
  output logic                s_awready,
  input  logic [ID_W-1:0]     s_awid,
  input  logic [ADDR_W-1:0]   s_awaddr,
  input  logic [7:0]          s_awlen,
  input  logic [2:0]          s_awsize,
  input  logic [1:0]          s_awburst,
  input  logic                s_awlock,
  input  logic [3:0]          s_awcache,
  input  logic [2:0]          s_awprot,
  input  logic [3:0]          s_awqos,
  input  logic [3:0]          s_awregion,
  input  logic                s_wvalid,
  output logic                s_wready,
  input  logic [DATA_W-1:0]   s_wdata,
  input  logic [DATA_W/8-1:0] s_wstrb,
  input  logic                s_wlast,
  output logic                s_bvalid,
  input  logic                s_bready,
  output logic [ID_W-1:0]     s_bid,
  output logic [1:0]          s_bresp,
  // Master (downstream) side
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [ID_W-1:0]     m_arid,
  output logic [ADDR_W-1:0]   m_araddr,
  output logic [7:0]          m_arlen,
  output logic [2:0]          m_arsize,
  output logic [1:0]          m_arburst,
  output logic                m_arlock,
  output logic [3:0]          m_arcache,
  output logic [2:0]          m_arprot,
  output logic [3:0]          m_arqos,
  output logic [3:0]          m_arregion,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [ID_W-1:0]     m_rid,
  input  logic [DATA_W-1:0]   m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast,
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [ID_W-1:0]     m_awid,
  output logic [ADDR_W-1:0]   m_awaddr,
  output logic [7:0]          m_awlen,
  output logic [2:0]          m_awsize,
  output logic [1:0]          m_awburst,
  output logic                m_awlock,
  output logic [3:0]          m_awcache,
  output logic [2:0]          m_awprot,
  output logic [3:0]          m_awqos,
  output logic [3:0]          m_awregion,
  output logic                m_wvalid,
  input  logic                m_wready,
  output logic [DATA_W-1:0]   m_wdata,
  output logic [DATA_W/8-1:0] m_wstrb,
  output logic                m_wlast,
  input  logic                m_bvalid,
  output logic                m_bready,
  input  logic [ID_W-1:0]     m_bid,
  input  logic [1:0]          m_bresp
);

  localparam int STRB_W = DATA_W / 8;
  localparam int AX_W   = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4;
  localparam int R_W    = ID_W + DATA_W + 2 + 1;
  localparam int W_W    = DATA_W + STRB_W + 1;
  localparam int B_W    = ID_W + 2;

  soc_axi_skid #(.WIDTH(AX_W)) u_ar (
    .clk, .rst_n,
    .s_valid(s_arvalid), .s_ready(s_arready),
    .s_data({s_arid, s_araddr, s_arlen, s_arsize, s_arburst, s_arlock, s_arcache, s_arprot, s_arqos, s_arregion}),
    .m_valid(m_arvalid), .m_ready(m_arready),
    .m_data({m_arid, m_araddr, m_arlen, m_arsize, m_arburst, m_arlock, m_arcache, m_arprot, m_arqos, m_arregion})
  );

  soc_axi_skid #(.WIDTH(R_W)) u_r (
    .clk, .rst_n,
    .s_valid(m_rvalid), .s_ready(m_rready),
    .s_data({m_rid, m_rdata, m_rresp, m_rlast}),
    .m_valid(s_rvalid), .m_ready(s_rready),
    .m_data({s_rid, s_rdata, s_rresp, s_rlast})
  );

  soc_axi_skid #(.WIDTH(AX_W)) u_aw (
    .clk, .rst_n,
    .s_valid(s_awvalid), .s_ready(s_awready),
    .s_data({s_awid, s_awaddr, s_awlen, s_awsize, s_awburst, s_awlock, s_awcache, s_awprot, s_awqos, s_awregion}),
    .m_valid(m_awvalid), .m_ready(m_awready),
    .m_data({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst, m_awlock, m_awcache, m_awprot, m_awqos, m_awregion})
  );

  soc_axi_skid #(.WIDTH(W_W)) u_w (
    .clk, .rst_n,
    .s_valid(s_wvalid), .s_ready(s_wready),
    .s_data({s_wdata, s_wstrb, s_wlast}),
    .m_valid(m_wvalid), .m_ready(m_wready),
    .m_data({m_wdata, m_wstrb, m_wlast})
  );

  soc_axi_skid #(.WIDTH(B_W)) u_b (
    .clk, .rst_n,
    .s_valid(m_bvalid), .s_ready(m_bready),
    .s_data({m_bid, m_bresp}),
    .m_valid(s_bvalid), .m_ready(s_bready),
    .m_data({s_bid, s_bresp})
  );

endmodule

`default_nettype wire
