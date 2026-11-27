// Ref: docs/modules/soc_axi.md  Parameterized Full-AXI4 N-Master x M-Slave Crossbar Top
`default_nettype none

// Combines independent Full-AXI4 Read Crossbar (soc_axi_xbar_rd) and Write Crossbar (soc_axi_xbar_wr).
module soc_axi_xbar import soc_axi_pkg::*; #(
  parameter int NM      = 2,
  parameter int NS      = 2,
  parameter int DATA_W  = 64,
  parameter int ADDR_W  = 32,
  parameter int M_ID_W  = 6,
  parameter int M_IDX_W = (NM > 1) ? $clog2(NM) : 1,
  parameter int S_ID_W  = M_ID_W + M_IDX_W,
  parameter int SLV_W   = $clog2(NS + 1),
  parameter int MAX_RD  = 16,
  parameter int MAX_WR  = 8
) (
  input  logic                clk,
  input  logic                rst_n,
  // NM Master ports
  input  logic [NM-1:0]       m_arvalid,
  output logic [NM-1:0]       m_arready,
  input  logic [SLV_W-1:0]    m_ar_slv    [NM],
  input  logic [M_ID_W-1:0]   m_arid      [NM],
  input  logic [ADDR_W-1:0]   m_araddr    [NM],
  input  logic [7:0]          m_arlen     [NM],
  input  logic [2:0]          m_arsize    [NM],
  input  logic [1:0]          m_arburst   [NM],
  input  logic [NM-1:0]       m_arlock,
  input  logic [3:0]          m_arcache   [NM],
  input  logic [2:0]          m_arprot    [NM],
  input  logic [3:0]          m_arqos     [NM],
  input  logic [3:0]          m_arregion  [NM],
  output logic [NM-1:0]       m_rvalid,
  input  logic [NM-1:0]       m_rready,
  output logic [M_ID_W-1:0]   m_rid       [NM],
  output logic [DATA_W-1:0]   m_rdata     [NM],
  output logic [1:0]          m_rresp     [NM],
  output logic [NM-1:0]       m_rlast,
  input  logic [NM-1:0]       m_awvalid,
  output logic [NM-1:0]       m_awready,
  input  logic [SLV_W-1:0]    m_aw_slv    [NM],
  input  logic [M_ID_W-1:0]   m_awid      [NM],
  input  logic [ADDR_W-1:0]   m_awaddr    [NM],
  input  logic [7:0]          m_awlen     [NM],
  input  logic [2:0]          m_awsize    [NM],
  input  logic [1:0]          m_awburst   [NM],
  input  logic [NM-1:0]       m_awlock,
  input  logic [3:0]          m_awcache   [NM],
  input  logic [2:0]          m_awprot    [NM],
  input  logic [3:0]          m_awqos     [NM],
  input  logic [3:0]          m_awregion  [NM],
  input  logic [NM-1:0]       m_wvalid,
  output logic [NM-1:0]       m_wready,
  input  logic [DATA_W-1:0]   m_wdata     [NM],
  input  logic [DATA_W/8-1:0] m_wstrb     [NM],
  input  logic [NM-1:0]       m_wlast,
  output logic [NM-1:0]       m_bvalid,
  input  logic [NM-1:0]       m_bready,
  output logic [M_ID_W-1:0]   m_bid       [NM],
  output logic [1:0]          m_bresp     [NM],
  // NS Slave ports
  output logic [NS-1:0]       s_arvalid,
  input  logic [NS-1:0]       s_arready,
  output logic [S_ID_W-1:0]   s_arid      [NS],
  output logic [ADDR_W-1:0]   s_araddr    [NS],
  output logic [7:0]          s_arlen     [NS],
  output logic [2:0]          s_arsize    [NS],
  output logic [1:0]          s_arburst   [NS],
  output logic [NS-1:0]       s_arlock,
  output logic [3:0]          s_arcache   [NS],
  output logic [2:0]          s_arprot    [NS],
  output logic [3:0]          s_arqos     [NS],
  output logic [3:0]          s_arregion  [NS],
  input  logic [NS-1:0]       s_rvalid,
  output logic [NS-1:0]       s_rready,
  input  logic [S_ID_W-1:0]   s_rid       [NS],
  input  logic [DATA_W-1:0]   s_rdata     [NS],
  input  logic [1:0]          s_rresp     [NS],
  input  logic [NS-1:0]       s_rlast,
  output logic [NS-1:0]       s_awvalid,
  input  logic [NS-1:0]       s_awready,
  output logic [S_ID_W-1:0]   s_awid      [NS],
  output logic [ADDR_W-1:0]   s_awaddr    [NS],
  output logic [7:0]          s_awlen     [NS],
  output logic [2:0]          s_awsize    [NS],
  output logic [1:0]          s_awburst   [NS],
  output logic [NS-1:0]       s_awlock,
  output logic [3:0]          s_awcache   [NS],
  output logic [2:0]          s_awprot    [NS],
  output logic [3:0]          s_awqos     [NS],
  output logic [3:0]          s_awregion  [NS],
  output logic [NS-1:0]       s_wvalid,
  input  logic [NS-1:0]       s_wready,
  output logic [DATA_W-1:0]   s_wdata     [NS],
  output logic [DATA_W/8-1:0] s_wstrb     [NS],
  output logic [NS-1:0]       s_wlast,
  input  logic [NS-1:0]       s_bvalid,
  output logic [NS-1:0]       s_bready,
  input  logic [S_ID_W-1:0]   s_bid       [NS],
  input  logic [1:0]          s_bresp     [NS]
);

  soc_axi_xbar_rd #(
    .NM(NM), .NS(NS), .DATA_W(DATA_W), .ADDR_W(ADDR_W),
    .M_ID_W(M_ID_W), .M_IDX_W(M_IDX_W), .S_ID_W(S_ID_W), .SLV_W(SLV_W), .MAX_OUT(MAX_RD)
  ) u_rd (
    .clk, .rst_n,
    .m_arvalid, .m_arready, .m_ar_slv, .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst,
    .m_arlock, .m_arcache, .m_arprot, .m_arqos, .m_arregion,
    .m_rvalid, .m_rready, .m_rid, .m_rdata, .m_rresp, .m_rlast,
    .s_arvalid, .s_arready, .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst,
    .s_arlock, .s_arcache, .s_arprot, .s_arqos, .s_arregion,
    .s_rvalid, .s_rready, .s_rid, .s_rdata, .s_rresp, .s_rlast
  );

  soc_axi_xbar_wr #(
    .NM(NM), .NS(NS), .DATA_W(DATA_W), .ADDR_W(ADDR_W),
    .M_ID_W(M_ID_W), .M_IDX_W(M_IDX_W), .S_ID_W(S_ID_W), .SLV_W(SLV_W), .MAX_OUT(MAX_WR)
  ) u_wr (
    .clk, .rst_n,
    .m_awvalid, .m_awready, .m_aw_slv, .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst,
    .m_awlock, .m_awcache, .m_awprot, .m_awqos, .m_awregion,
    .m_wvalid, .m_wready, .m_wdata, .m_wstrb, .m_wlast,
    .m_bvalid, .m_bready, .m_bid, .m_bresp,
    .s_awvalid, .s_awready, .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst,
    .s_awlock, .s_awcache, .s_awprot, .s_awqos, .s_awregion,
    .s_wvalid, .s_wready, .s_wdata, .s_wstrb, .s_wlast,
    .s_bvalid, .s_bready, .s_bid, .s_bresp
  );

endmodule

`default_nettype wire
