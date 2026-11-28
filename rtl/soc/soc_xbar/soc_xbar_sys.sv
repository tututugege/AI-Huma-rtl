// Ref: docs/modules/soc_axi.md  Tier-1 256-bit System AXI4 Fabric (Core LLC -> DDR + On-Chip 64b)
`default_nettype none

// Tier-1 System AXI4 Interconnect:
//   Core LLC 256b -> RegSlice -> 1M x 2S 256b Full-AXI4 Xbar:
//     S0 (DDR, addr[31]==1)     -> Downsizer (256b -> DDR_DATA_W) -> RegSlice -> External DDR pins
//     S1 (On-Chip, addr[31]==0) -> Downsizer (256b -> 64b) -> Tier-2 On-Chip AXI4 Xbar M1
module soc_xbar_sys import soc_axi_pkg::*; #(
  parameter int DDR_DATA_W = 64,
  parameter int DDR_ID_W   = 7
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Core LLC 256-bit AXI4 port (from mem_top d_*)
  input  logic                    c_arvalid,
  output logic                    c_arready,
  input  logic [5:0]              c_arid,
  input  logic [31:0]             c_araddr,
  input  logic [7:0]              c_arlen,
  output logic                    c_rvalid,
  input  logic                    c_rready,
  output logic [5:0]              c_rid,
  output logic [255:0]            c_rdata,
  input  logic                    c_awvalid,
  output logic                    c_awready,
  input  logic [5:0]              c_awid,
  input  logic [31:0]             c_awaddr,
  input  logic [7:0]              c_awlen,
  input  logic                    c_wvalid,
  output logic                    c_wready,
  input  logic [255:0]            c_wdata,
  input  logic [31:0]             c_wstrb,
  input  logic                    c_wlast,
  output logic                    c_bvalid,
  input  logic                    c_bready,
  output logic [5:0]              c_bid,
  output logic [1:0]              c_bresp,
  // External Standard Full-AXI4 DDR Master port
  output logic                    ddr_arvalid,
  input  logic                    ddr_arready,
  output logic [DDR_ID_W-1:0]     ddr_arid,
  output logic [31:0]             ddr_araddr,
  output logic [7:0]              ddr_arlen,
  output logic [2:0]              ddr_arsize,
  output logic [1:0]              ddr_arburst,
  output logic                    ddr_arlock,
  output logic [3:0]              ddr_arcache,
  output logic [2:0]              ddr_arprot,
  output logic [3:0]              ddr_arqos,
  output logic [3:0]              ddr_arregion,
  input  logic                    ddr_rvalid,
  output logic                    ddr_rready,
  input  logic [DDR_ID_W-1:0]     ddr_rid,
  input  logic [DDR_DATA_W-1:0]   ddr_rdata,
  input  logic [1:0]              ddr_rresp,
  input  logic                    ddr_rlast,
  output logic                    ddr_awvalid,
  input  logic                    ddr_awready,
  output logic [DDR_ID_W-1:0]     ddr_awid,
  output logic [31:0]             ddr_awaddr,
  output logic [7:0]              ddr_awlen,
  output logic [2:0]              ddr_awsize,
  output logic [1:0]              ddr_awburst,
  output logic                    ddr_awlock,
  output logic [3:0]              ddr_awcache,
  output logic [2:0]              ddr_awprot,
  output logic [3:0]              ddr_awqos,
  output logic [3:0]              ddr_awregion,
  output logic                    ddr_wvalid,
  input  logic                    ddr_wready,
  output logic [DDR_DATA_W-1:0]   ddr_wdata,
  output logic [DDR_DATA_W/8-1:0] ddr_wstrb,
  output logic                    ddr_wlast,
  input  logic                    ddr_bvalid,
  output logic                    ddr_bready,
  input  logic [DDR_ID_W-1:0]     ddr_bid,
  input  logic [1:0]              ddr_bresp,
  // Downsized 64-bit Full-AXI4 Master into Tier-2 On-Chip Xbar
  output logic                    oc_arvalid,
  input  logic                    oc_arready,
  output logic [DDR_ID_W-1:0]     oc_arid,
  output logic [31:0]             oc_araddr,
  output logic [7:0]              oc_arlen,
  output logic [2:0]              oc_arsize,
  output logic [1:0]              oc_arburst,
  output logic                    oc_arlock,
  output logic [3:0]              oc_arcache,
  output logic [2:0]              oc_arprot,
  output logic [3:0]              oc_arqos,
  output logic [3:0]              oc_arregion,
  input  logic                    oc_rvalid,
  output logic                    oc_rready,
  input  logic [DDR_ID_W-1:0]     oc_rid,
  input  logic [63:0]             oc_rdata,
  input  logic [1:0]              oc_rresp,
  input  logic                    oc_rlast,
  output logic                    oc_awvalid,
  input  logic                    oc_awready,
  output logic [DDR_ID_W-1:0]     oc_awid,
  output logic [31:0]             oc_awaddr,
  output logic [7:0]              oc_awlen,
  output logic [2:0]              oc_awsize,
  output logic [1:0]              oc_awburst,
  output logic                    oc_awlock,
  output logic [3:0]              oc_awcache,
  output logic [2:0]              oc_awprot,
  output logic [3:0]              oc_awqos,
  output logic [3:0]              oc_awregion,
  output logic                    oc_wvalid,
  input  logic                    oc_wready,
  output logic [63:0]             oc_wdata,
  output logic [7:0]              oc_wstrb,
  output logic                    oc_wlast,
  input  logic                    oc_bvalid,
  output logic                    oc_bready,
  input  logic [DDR_ID_W-1:0]     oc_bid,
  input  logic [1:0]              oc_bresp
);

  // Core LLC 256-bit Register Slice (timing isolation + full AXI4 attribute normalization)
  logic         cr_arvalid, cr_arready, cr_rvalid, cr_rready, cr_rlast, cr_arlock, cr_awlock;
  logic         cr_awvalid, cr_awready, cr_wvalid, cr_wready, cr_wlast, cr_bvalid, cr_bready;
  logic [5:0]   cr_arid, cr_rid, cr_awid, cr_bid;
  logic [31:0]  cr_araddr, cr_awaddr, cr_wstrb;
  logic [7:0]   cr_arlen, cr_awlen;
  logic [2:0]   cr_arsize, cr_awsize, cr_arprot, cr_awprot;
  logic [1:0]   cr_arburst, cr_awburst, cr_rresp, cr_bresp;
  logic [3:0]   cr_arcache, cr_awcache, cr_arqos, cr_awqos, cr_arregion, cr_awregion;
  logic [255:0] cr_rdata, cr_wdata;
  logic [1:0]   c_rresp_unused;
  logic         c_rlast_unused;

  soc_axi_reg_slice #(.DATA_W(256), .ADDR_W(32), .ID_W(6)) u_core_slice (
    .clk, .rst_n,
    .s_arvalid(c_arvalid), .s_arready(c_arready), .s_arid(c_arid), .s_araddr(c_araddr),
    .s_arlen(c_arlen), .s_arsize(3'd5), .s_arburst(AXI4_BURST_INCR), .s_arlock(1'b0),
    .s_arcache(AXI4_CACHE_NORM_NC_BUF), .s_arprot(AXI4_PROT_DATA_NONSEC), .s_arqos(4'd0), .s_arregion(4'd0),
    .s_rvalid(c_rvalid), .s_rready(c_rready), .s_rid(c_rid), .s_rdata(c_rdata),
    .s_rresp(c_rresp_unused), .s_rlast(c_rlast_unused),
    .s_awvalid(c_awvalid), .s_awready(c_awready), .s_awid(c_awid), .s_awaddr(c_awaddr),
    .s_awlen(c_awlen), .s_awsize(3'd5), .s_awburst(AXI4_BURST_INCR), .s_awlock(1'b0),
    .s_awcache(AXI4_CACHE_NORM_NC_BUF), .s_awprot(AXI4_PROT_DATA_NONSEC), .s_awqos(4'd0), .s_awregion(4'd0),
    .s_wvalid(c_wvalid), .s_wready(c_wready), .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wlast(c_wlast),
    .s_bvalid(c_bvalid), .s_bready(c_bready), .s_bid(c_bid), .s_bresp(c_bresp),
    .m_arvalid(cr_arvalid), .m_arready(cr_arready), .m_arid(cr_arid), .m_araddr(cr_araddr),
    .m_arlen(cr_arlen), .m_arsize(cr_arsize), .m_arburst(cr_arburst), .m_arlock(cr_arlock),
    .m_arcache(cr_arcache), .m_arprot(cr_arprot), .m_arqos(cr_arqos), .m_arregion(cr_arregion),
    .m_rvalid(cr_rvalid), .m_rready(cr_rready), .m_rid(cr_rid), .m_rdata(cr_rdata),
    .m_rresp(cr_rresp), .m_rlast(cr_rlast),
    .m_awvalid(cr_awvalid), .m_awready(cr_awready), .m_awid(cr_awid), .m_awaddr(cr_awaddr),
    .m_awlen(cr_awlen), .m_awsize(cr_awsize), .m_awburst(cr_awburst), .m_awlock(cr_awlock),
    .m_awcache(cr_awcache), .m_awprot(cr_awprot), .m_awqos(cr_awqos), .m_awregion(cr_awregion),
    .m_wvalid(cr_wvalid), .m_wready(cr_wready), .m_wdata(cr_wdata), .m_wstrb(cr_wstrb), .m_wlast(cr_wlast),
    .m_bvalid(cr_bvalid), .m_bready(cr_bready), .m_bid(cr_bid), .m_bresp(cr_bresp)
  );

  // System Xbar 1M x 2S (256-bit): S0 = DDR (addr[31]==1), S1 = On-Chip (addr[31]==0)
  logic [0:0]          sm_arvalid, sm_arready, sm_rvalid, sm_rready, sm_rlast, sm_arlock, sm_awlock;
  logic [0:0]          sm_awvalid, sm_awready, sm_wvalid, sm_wready, sm_wlast, sm_bvalid, sm_bready;
  logic [1:0]          sm_ar_slv [1], sm_aw_slv [1], sm_arburst [1], sm_awburst [1], sm_rresp [1], sm_bresp [1];
  logic [5:0]          sm_arid [1], sm_rid [1], sm_awid [1], sm_bid [1];
  logic [31:0]         sm_araddr [1], sm_awaddr [1], sm_wstrb [1];
  logic [7:0]          sm_arlen [1], sm_awlen [1];
  logic [2:0]          sm_arsize [1], sm_awsize [1], sm_arprot [1], sm_awprot [1];
  logic [3:0]          sm_arcache [1], sm_awcache [1], sm_arqos [1], sm_awqos [1], sm_arregion [1], sm_awregion [1];
  logic [255:0]        sm_rdata [1], sm_wdata [1];

  assign sm_arvalid[0] = cr_arvalid; assign cr_arready = sm_arready[0];
  assign sm_ar_slv[0]  = cr_araddr[31] ? 2'd0 : 2'd1;
  assign sm_arid[0]    = cr_arid;    assign sm_araddr[0]   = cr_araddr; assign sm_arlen[0]  = cr_arlen;
  assign sm_arsize[0]  = cr_arsize;  assign sm_arburst[0]  = cr_arburst; assign sm_arlock[0] = cr_arlock;
  assign sm_arcache[0] = cr_arcache; assign sm_arprot[0]   = cr_arprot; assign sm_arqos[0]  = cr_arqos;
  assign sm_arregion[0] = cr_arregion;
  assign cr_rvalid     = sm_rvalid[0]; assign sm_rready[0] = cr_rready; assign cr_rid   = sm_rid[0];
  assign cr_rdata      = sm_rdata[0];  assign cr_rresp     = sm_rresp[0]; assign cr_rlast = sm_rlast[0];
  assign sm_awvalid[0] = cr_awvalid; assign cr_awready = sm_awready[0];
  assign sm_aw_slv[0]  = cr_awaddr[31] ? 2'd0 : 2'd1;
  assign sm_awid[0]    = cr_awid;    assign sm_awaddr[0]   = cr_awaddr; assign sm_awlen[0]  = cr_awlen;
  assign sm_awsize[0]  = cr_awsize;  assign sm_awburst[0]  = cr_awburst; assign sm_awlock[0] = cr_awlock;
  assign sm_awcache[0] = cr_awcache; assign sm_awprot[0]   = cr_awprot; assign sm_awqos[0]  = cr_awqos;
  assign sm_awregion[0] = cr_awregion;
  assign sm_wvalid[0]  = cr_wvalid;  assign cr_wready = sm_wready[0]; assign sm_wdata[0] = cr_wdata;
  assign sm_wstrb[0]   = cr_wstrb;   assign sm_wlast[0] = cr_wlast;
  assign cr_bvalid     = sm_bvalid[0]; assign sm_bready[0] = cr_bready;
  assign cr_bid        = sm_bid[0];    assign cr_bresp     = sm_bresp[0];

  logic [1:0]          ss_arvalid, ss_arready, ss_rvalid, ss_rready, ss_rlast, ss_arlock, ss_awlock;
  logic [1:0]          ss_awvalid, ss_awready, ss_wvalid, ss_wready, ss_wlast, ss_bvalid, ss_bready;
  logic [DDR_ID_W-1:0] ss_arid [2], ss_rid [2], ss_awid [2], ss_bid [2];
  logic [31:0]         ss_araddr [2], ss_awaddr [2], ss_wstrb [2];
  logic [7:0]          ss_arlen [2], ss_awlen [2];
  logic [2:0]          ss_arsize [2], ss_awsize [2], ss_arprot [2], ss_awprot [2];
  logic [1:0]          ss_arburst [2], ss_awburst [2], ss_rresp [2], ss_bresp [2];
  logic [3:0]          ss_arcache [2], ss_awcache [2], ss_arqos [2], ss_awqos [2], ss_arregion [2], ss_awregion [2];
  logic [255:0]        ss_rdata [2], ss_wdata [2];

  soc_axi_xbar #(
    .NM(1), .NS(2), .DATA_W(256), .ADDR_W(32), .M_ID_W(6), .M_IDX_W(1),
    .S_ID_W(DDR_ID_W), .SLV_W(2), .MAX_RD(16), .MAX_WR(4)
  ) u_sys_xbar (
    .clk, .rst_n,
    .m_arvalid(sm_arvalid), .m_arready(sm_arready), .m_ar_slv(sm_ar_slv), .m_arid(sm_arid),
    .m_araddr(sm_araddr), .m_arlen(sm_arlen), .m_arsize(sm_arsize), .m_arburst(sm_arburst),
    .m_arlock(sm_arlock), .m_arcache(sm_arcache), .m_arprot(sm_arprot), .m_arqos(sm_arqos),
    .m_arregion(sm_arregion), .m_rvalid(sm_rvalid), .m_rready(sm_rready), .m_rid(sm_rid),
    .m_rdata(sm_rdata), .m_rresp(sm_rresp), .m_rlast(sm_rlast),
    .m_awvalid(sm_awvalid), .m_awready(sm_awready), .m_aw_slv(sm_aw_slv), .m_awid(sm_awid),
    .m_awaddr(sm_awaddr), .m_awlen(sm_awlen), .m_awsize(sm_awsize), .m_awburst(sm_awburst),
    .m_awlock(sm_awlock), .m_awcache(sm_awcache), .m_awprot(sm_awprot), .m_awqos(sm_awqos),
    .m_awregion(sm_awregion), .m_wvalid(sm_wvalid), .m_wready(sm_wready), .m_wdata(sm_wdata),
    .m_wstrb(sm_wstrb), .m_wlast(sm_wlast), .m_bvalid(sm_bvalid), .m_bready(sm_bready),
    .m_bid(sm_bid), .m_bresp(sm_bresp),
    .s_arvalid(ss_arvalid), .s_arready(ss_arready), .s_arid(ss_arid), .s_araddr(ss_araddr),
    .s_arlen(ss_arlen), .s_arsize(ss_arsize), .s_arburst(ss_arburst), .s_arlock(ss_arlock),
    .s_arcache(ss_arcache), .s_arprot(ss_arprot), .s_arqos(ss_arqos), .s_arregion(ss_arregion),
    .s_rvalid(ss_rvalid), .s_rready(ss_rready), .s_rid(ss_rid), .s_rdata(ss_rdata),
    .s_rresp(ss_rresp), .s_rlast(ss_rlast),
    .s_awvalid(ss_awvalid), .s_awready(ss_awready), .s_awid(ss_awid), .s_awaddr(ss_awaddr),
    .s_awlen(ss_awlen), .s_awsize(ss_awsize), .s_awburst(ss_awburst), .s_awlock(ss_awlock),
    .s_awcache(ss_awcache), .s_awprot(ss_awprot), .s_awqos(ss_awqos), .s_awregion(ss_awregion),
    .s_wvalid(ss_wvalid), .s_wready(ss_wready), .s_wdata(ss_wdata), .s_wstrb(ss_wstrb),
    .s_wlast(ss_wlast), .s_bvalid(ss_bvalid), .s_bready(ss_bready), .s_bid(ss_bid), .s_bresp(ss_bresp)
  );

  // S0 (DDR): Downsizer (256b -> DDR_DATA_W) -> 5-channel RegSlice -> chip pins
  logic                    dd_arvalid, dd_arready, dd_rvalid, dd_rready, dd_rlast, dd_arlock, dd_awlock;
  logic                    dd_awvalid, dd_awready, dd_wvalid, dd_wready, dd_wlast, dd_bvalid, dd_bready;
  logic [DDR_ID_W-1:0]     dd_arid, dd_rid, dd_awid, dd_bid;
  logic [31:0]             dd_araddr, dd_awaddr;
  logic [7:0]              dd_arlen, dd_awlen;
  logic [2:0]              dd_arsize, dd_awsize, dd_arprot, dd_awprot;
  logic [1:0]              dd_arburst, dd_awburst, dd_rresp, dd_bresp;
  logic [3:0]              dd_arcache, dd_awcache, dd_arqos, dd_awqos, dd_arregion, dd_awregion;
  logic [DDR_DATA_W-1:0]   dd_rdata, dd_wdata;
  logic [DDR_DATA_W/8-1:0] dd_wstrb;

  soc_axi_downsizer #(
    .S_DATA_W(256), .M_DATA_W(DDR_DATA_W), .ADDR_W(32), .ID_W(DDR_ID_W), .MAX_RD_OUT(16), .MAX_WR_OUT(4)
  ) u_ddr_down (
    .clk, .rst_n,
    .s_arvalid(ss_arvalid[0]), .s_arready(ss_arready[0]), .s_arid(ss_arid[0]), .s_araddr(ss_araddr[0]),
    .s_arlen(ss_arlen[0]), .s_arsize(ss_arsize[0]), .s_arburst(ss_arburst[0]), .s_arlock(ss_arlock[0]),
    .s_arcache(ss_arcache[0]), .s_arprot(ss_arprot[0]), .s_arqos(ss_arqos[0]), .s_arregion(ss_arregion[0]),
    .s_rvalid(ss_rvalid[0]), .s_rready(ss_rready[0]), .s_rid(ss_rid[0]), .s_rdata(ss_rdata[0]),
    .s_rresp(ss_rresp[0]), .s_rlast(ss_rlast[0]),
    .s_awvalid(ss_awvalid[0]), .s_awready(ss_awready[0]), .s_awid(ss_awid[0]), .s_awaddr(ss_awaddr[0]),
    .s_awlen(ss_awlen[0]), .s_awsize(ss_awsize[0]), .s_awburst(ss_awburst[0]), .s_awlock(ss_awlock[0]),
    .s_awcache(ss_awcache[0]), .s_awprot(ss_awprot[0]), .s_awqos(ss_awqos[0]), .s_awregion(ss_awregion[0]),
    .s_wvalid(ss_wvalid[0]), .s_wready(ss_wready[0]), .s_wdata(ss_wdata[0]), .s_wstrb(ss_wstrb[0]),
    .s_wlast(ss_wlast[0]), .s_bvalid(ss_bvalid[0]), .s_bready(ss_bready[0]), .s_bid(ss_bid[0]), .s_bresp(ss_bresp[0]),
    .m_arvalid(dd_arvalid), .m_arready(dd_arready), .m_arid(dd_arid), .m_araddr(dd_araddr),
    .m_arlen(dd_arlen), .m_arsize(dd_arsize), .m_arburst(dd_arburst), .m_arlock(dd_arlock),
    .m_arcache(dd_arcache), .m_arprot(dd_arprot), .m_arqos(dd_arqos), .m_arregion(dd_arregion),
    .m_rvalid(dd_rvalid), .m_rready(dd_rready), .m_rid(dd_rid), .m_rdata(dd_rdata),
    .m_rresp(dd_rresp), .m_rlast(dd_rlast),
    .m_awvalid(dd_awvalid), .m_awready(dd_awready), .m_awid(dd_awid), .m_awaddr(dd_awaddr),
    .m_awlen(dd_awlen), .m_awsize(dd_awsize), .m_awburst(dd_awburst), .m_awlock(dd_awlock),
    .m_awcache(dd_awcache), .m_awprot(dd_awprot), .m_awqos(dd_awqos), .m_awregion(dd_awregion),
    .m_wvalid(dd_wvalid), .m_wready(dd_wready), .m_wdata(dd_wdata), .m_wstrb(dd_wstrb), .m_wlast(dd_wlast),
    .m_bvalid(dd_bvalid), .m_bready(dd_bready), .m_bid(dd_bid), .m_bresp(dd_bresp)
  );

  soc_axi_reg_slice #(.DATA_W(DDR_DATA_W), .ADDR_W(32), .ID_W(DDR_ID_W)) u_ddr_slice (
    .clk, .rst_n,
    .s_arvalid(dd_arvalid), .s_arready(dd_arready), .s_arid(dd_arid), .s_araddr(dd_araddr),
    .s_arlen(dd_arlen), .s_arsize(dd_arsize), .s_arburst(dd_arburst), .s_arlock(dd_arlock),
    .s_arcache(dd_arcache), .s_arprot(dd_arprot), .s_arqos(dd_arqos), .s_arregion(dd_arregion),
    .s_rvalid(dd_rvalid), .s_rready(dd_rready), .s_rid(dd_rid), .s_rdata(dd_rdata),
    .s_rresp(dd_rresp), .s_rlast(dd_rlast),
    .s_awvalid(dd_awvalid), .s_awready(dd_awready), .s_awid(dd_awid), .s_awaddr(dd_awaddr),
    .s_awlen(dd_awlen), .s_awsize(dd_awsize), .s_awburst(dd_awburst), .s_awlock(dd_awlock),
    .s_awcache(dd_awcache), .s_awprot(dd_awprot), .s_awqos(dd_awqos), .s_awregion(dd_awregion),
    .s_wvalid(dd_wvalid), .s_wready(dd_wready), .s_wdata(dd_wdata), .s_wstrb(dd_wstrb), .s_wlast(dd_wlast),
    .s_bvalid(dd_bvalid), .s_bready(dd_bready), .s_bid(dd_bid), .s_bresp(dd_bresp),
    .m_arvalid(ddr_arvalid), .m_arready(ddr_arready), .m_arid(ddr_arid), .m_araddr(ddr_araddr),
    .m_arlen(ddr_arlen), .m_arsize(ddr_arsize), .m_arburst(ddr_arburst), .m_arlock(ddr_arlock),
    .m_arcache(ddr_arcache), .m_arprot(ddr_arprot), .m_arqos(ddr_arqos), .m_arregion(ddr_arregion),
    .m_rvalid(ddr_rvalid), .m_rready(ddr_rready), .m_rid(ddr_rid), .m_rdata(ddr_rdata),
    .m_rresp(ddr_rresp), .m_rlast(ddr_rlast),
    .m_awvalid(ddr_awvalid), .m_awready(ddr_awready), .m_awid(ddr_awid), .m_awaddr(ddr_awaddr),
    .m_awlen(ddr_awlen), .m_awsize(ddr_awsize), .m_awburst(ddr_awburst), .m_awlock(ddr_awlock),
    .m_awcache(ddr_awcache), .m_awprot(ddr_awprot), .m_awqos(ddr_awqos), .m_awregion(ddr_awregion),
    .m_wvalid(ddr_wvalid), .m_wready(ddr_wready), .m_wdata(ddr_wdata), .m_wstrb(ddr_wstrb), .m_wlast(ddr_wlast),
    .m_bvalid(ddr_bvalid), .m_bready(ddr_bready), .m_bid(ddr_bid), .m_bresp(ddr_bresp)
  );

  // S1 (On-Chip): Downsizer (256b -> 64b) into Tier-2 On-Chip Xbar
  soc_axi_downsizer #(
    .S_DATA_W(256), .M_DATA_W(64), .ADDR_W(32), .ID_W(DDR_ID_W), .MAX_RD_OUT(8), .MAX_WR_OUT(4)
  ) u_oc_down (
    .clk, .rst_n,
    .s_arvalid(ss_arvalid[1]), .s_arready(ss_arready[1]), .s_arid(ss_arid[1]), .s_araddr(ss_araddr[1]),
    .s_arlen(ss_arlen[1]), .s_arsize(ss_arsize[1]), .s_arburst(ss_arburst[1]), .s_arlock(ss_arlock[1]),
    .s_arcache(ss_arcache[1]), .s_arprot(ss_arprot[1]), .s_arqos(ss_arqos[1]), .s_arregion(ss_arregion[1]),
    .s_rvalid(ss_rvalid[1]), .s_rready(ss_rready[1]), .s_rid(ss_rid[1]), .s_rdata(ss_rdata[1]),
    .s_rresp(ss_rresp[1]), .s_rlast(ss_rlast[1]),
    .s_awvalid(ss_awvalid[1]), .s_awready(ss_awready[1]), .s_awid(ss_awid[1]), .s_awaddr(ss_awaddr[1]),
    .s_awlen(ss_awlen[1]), .s_awsize(ss_awsize[1]), .s_awburst(ss_awburst[1]), .s_awlock(ss_awlock[1]),
    .s_awcache(ss_awcache[1]), .s_awprot(ss_awprot[1]), .s_awqos(ss_awqos[1]), .s_awregion(ss_awregion[1]),
    .s_wvalid(ss_wvalid[1]), .s_wready(ss_wready[1]), .s_wdata(ss_wdata[1]), .s_wstrb(ss_wstrb[1]),
    .s_wlast(ss_wlast[1]), .s_bvalid(ss_bvalid[1]), .s_bready(ss_bready[1]), .s_bid(ss_bid[1]), .s_bresp(ss_bresp[1]),
    .m_arvalid(oc_arvalid), .m_arready(oc_arready), .m_arid(oc_arid), .m_araddr(oc_araddr),
    .m_arlen(oc_arlen), .m_arsize(oc_arsize), .m_arburst(oc_arburst), .m_arlock(oc_arlock),
    .m_arcache(oc_arcache), .m_arprot(oc_arprot), .m_arqos(oc_arqos), .m_arregion(oc_arregion),
    .m_rvalid(oc_rvalid), .m_rready(oc_rready), .m_rid(oc_rid), .m_rdata(oc_rdata),
    .m_rresp(oc_rresp), .m_rlast(oc_rlast),
    .m_awvalid(oc_awvalid), .m_awready(oc_awready), .m_awid(oc_awid), .m_awaddr(oc_awaddr),
    .m_awlen(oc_awlen), .m_awsize(oc_awsize), .m_awburst(oc_awburst), .m_awlock(oc_awlock),
    .m_awcache(oc_awcache), .m_awprot(oc_awprot), .m_awqos(oc_awqos), .m_awregion(oc_awregion),
    .m_wvalid(oc_wvalid), .m_wready(oc_wready), .m_wdata(oc_wdata), .m_wstrb(oc_wstrb), .m_wlast(oc_wlast),
    .m_bvalid(oc_bvalid), .m_bready(oc_bready), .m_bid(oc_bid), .m_bresp(oc_bresp)
  );

`ifndef SYNTHESIS
  soc_axi_checker #(.DATA_W(256), .ID_W(6), .NAME("core_llc_axi4")) u_chk_llc (
    .clk, .rst_n,
    .arvalid(cr_arvalid), .arready(cr_arready), .arid(cr_arid), .araddr(cr_araddr), .arlen(cr_arlen),
    .arsize(cr_arsize), .arburst(cr_arburst), .arlock(cr_arlock), .arcache(cr_arcache),
    .arprot(cr_arprot), .arqos(cr_arqos), .arregion(cr_arregion),
    .rvalid(cr_rvalid), .rready(cr_rready), .rid(cr_rid), .rdata(cr_rdata), .rresp(cr_rresp), .rlast(cr_rlast),
    .awvalid(cr_awvalid), .awready(cr_awready), .awid(cr_awid), .awaddr(cr_awaddr), .awlen(cr_awlen),
    .awsize(cr_awsize), .awburst(cr_awburst), .awlock(cr_awlock), .awcache(cr_awcache),
    .awprot(cr_awprot), .awqos(cr_awqos), .awregion(cr_awregion),
    .wvalid(cr_wvalid), .wready(cr_wready), .wdata(cr_wdata), .wstrb(cr_wstrb), .wlast(cr_wlast),
    .bvalid(cr_bvalid), .bready(cr_bready), .bid(cr_bid), .bresp(cr_bresp)
  );
  soc_axi_checker #(.DATA_W(DDR_DATA_W), .ID_W(DDR_ID_W), .NAME("chip_ddr_axi4")) u_chk_ddr (
    .clk, .rst_n,
    .arvalid(ddr_arvalid), .arready(ddr_arready), .arid(ddr_arid), .araddr(ddr_araddr), .arlen(ddr_arlen),
    .arsize(ddr_arsize), .arburst(ddr_arburst), .arlock(ddr_arlock), .arcache(ddr_arcache),
    .arprot(ddr_arprot), .arqos(ddr_arqos), .arregion(ddr_arregion),
    .rvalid(ddr_rvalid), .rready(ddr_rready), .rid(ddr_rid), .rdata(ddr_rdata), .rresp(ddr_rresp), .rlast(ddr_rlast),
    .awvalid(ddr_awvalid), .awready(ddr_awready), .awid(ddr_awid), .awaddr(ddr_awaddr), .awlen(ddr_awlen),
    .awsize(ddr_awsize), .awburst(ddr_awburst), .awlock(ddr_awlock), .awcache(ddr_awcache),
    .awprot(ddr_awprot), .awqos(ddr_awqos), .awregion(ddr_awregion),
    .wvalid(ddr_wvalid), .wready(ddr_wready), .wdata(ddr_wdata), .wstrb(ddr_wstrb), .wlast(ddr_wlast),
    .bvalid(ddr_bvalid), .bready(ddr_bready), .bid(ddr_bid), .bresp(ddr_bresp)
  );
`endif

endmodule

`default_nettype wire
