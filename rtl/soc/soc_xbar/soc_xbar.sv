// Ref: docs/modules/soc_axi.md  AI-Huma Real 2-Tier Full-AXI4 SoC Interconnect Top
`default_nettype none

// Top-level 2-tier Full-AXI4 SoC Interconnect:
//   - u_sys (soc_xbar_sys): Tier-1 256b System Xbar + DDR Downsizer/RegSlice + On-Chip 256b->64b Downsizer
//   - u_oc_xbar (soc_axi_xbar): Tier-2 64b 2M x 3S Full-AXI4 Xbar + built-in burst DECERR
//   - u_periph_bridge (soc_axi_to_lite): Full-AXI4 -> 4x AXI4-Lite peripherals (CLINT, PLIC, UART, SysCtrl)
module soc_xbar import soc_axi_pkg::*; import soc_pkg::*; #(
  parameter int DDR_DATA_W = 64,
  parameter int DDR_ID_W   = 7,
  parameter int OC_ID_W    = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Core LLC 256-bit AXI4 port
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
  // Core LSU Uncached MMIO Full 64-bit AXI4 port
  input  logic                    mmio_arvalid,
  output logic                    mmio_arready,
  input  logic [3:0]              mmio_arid,
  input  logic [31:0]             mmio_araddr,
  input  logic [7:0]              mmio_arlen,
  input  logic [2:0]              mmio_arsize,
  input  logic [1:0]              mmio_arburst,
  input  logic                    mmio_arlock,
  input  logic [3:0]              mmio_arcache,
  input  logic [2:0]              mmio_arprot,
  input  logic [3:0]              mmio_arqos,
  input  logic [3:0]              mmio_arregion,
  output logic                    mmio_rvalid,
  input  logic                    mmio_rready,
  output logic [3:0]              mmio_rid,
  output logic [63:0]             mmio_rdata,
  output logic [1:0]              mmio_rresp,
  output logic                    mmio_rlast,
  input  logic                    mmio_awvalid,
  output logic                    mmio_awready,
  input  logic [3:0]              mmio_awid,
  input  logic [31:0]             mmio_awaddr,
  input  logic [7:0]              mmio_awlen,
  input  logic [2:0]              mmio_awsize,
  input  logic [1:0]              mmio_awburst,
  input  logic                    mmio_awlock,
  input  logic [3:0]              mmio_awcache,
  input  logic [2:0]              mmio_awprot,
  input  logic [3:0]              mmio_awqos,
  input  logic [3:0]              mmio_awregion,
  input  logic                    mmio_wvalid,
  output logic                    mmio_wready,
  input  logic [63:0]             mmio_wdata,
  input  logic [7:0]              mmio_wstrb,
  input  logic                    mmio_wlast,
  output logic                    mmio_bvalid,
  input  logic                    mmio_bready,
  output logic [3:0]              mmio_bid,
  output logic [1:0]              mmio_bresp,
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
  // 2 Native 64-bit Full-AXI4 On-Chip Memory Slaves: 0=BootROM, 1=SRAM
  output logic [1:0]              mem_arvalid,
  input  logic [1:0]              mem_arready,
  output logic [OC_ID_W-1:0]      mem_arid     [2],
  output logic [31:0]             mem_araddr   [2],
  output logic [7:0]              mem_arlen    [2],
  output logic [2:0]              mem_arsize   [2],
  output logic [1:0]              mem_arburst  [2],
  output logic [1:0]              mem_arlock,
  output logic [3:0]              mem_arcache  [2],
  output logic [2:0]              mem_arprot   [2],
  output logic [3:0]              mem_arqos    [2],
  output logic [3:0]              mem_arregion [2],
  input  logic [1:0]              mem_rvalid,
  output logic [1:0]              mem_rready,
  input  logic [OC_ID_W-1:0]      mem_rid      [2],
  input  logic [63:0]             mem_rdata    [2],
  input  logic [1:0]              mem_rresp    [2],
  input  logic [1:0]              mem_rlast,
  output logic [1:0]              mem_awvalid,
  input  logic [1:0]              mem_awready,
  output logic [OC_ID_W-1:0]      mem_awid     [2],
  output logic [31:0]             mem_awaddr   [2],
  output logic [7:0]              mem_awlen    [2],
  output logic [2:0]              mem_awsize   [2],
  output logic [1:0]              mem_awburst  [2],
  output logic [1:0]              mem_awlock,
  output logic [3:0]              mem_awcache  [2],
  output logic [2:0]              mem_awprot   [2],
  output logic [3:0]              mem_awqos    [2],
  output logic [3:0]              mem_awregion [2],
  output logic [1:0]              mem_wvalid,
  input  logic [1:0]              mem_wready,
  output logic [63:0]             mem_wdata    [2],
  output logic [7:0]              mem_wstrb    [2],
  output logic [1:0]              mem_wlast,
  input  logic [1:0]              mem_bvalid,
  output logic [1:0]              mem_bready,
  input  logic [OC_ID_W-1:0]      mem_bid      [2],
  input  logic [1:0]              mem_bresp    [2],
  // 4 AXI4-Lite Peripheral Slaves: 0=CLINT, 1=PLIC, 2=UART, 3=SysCtrl
  output logic [3:0]              p_arvalid,
  input  logic [3:0]              p_arready,
  output logic [31:0]             p_araddr     [4],
  input  logic [3:0]              p_rvalid,
  output logic [3:0]              p_rready,
  input  logic [63:0]             p_rdata      [4],
  input  logic [1:0]              p_rresp      [4],
  output logic [3:0]              p_awvalid,
  input  logic [3:0]              p_awready,
  output logic [31:0]             p_awaddr     [4],
  output logic [3:0]              p_wvalid,
  input  logic [3:0]              p_wready,
  output logic [63:0]             p_wdata      [4],
  output logic [7:0]              p_wstrb      [4],
  input  logic [3:0]              p_bvalid,
  output logic [3:0]              p_bready,
  input  logic [1:0]              p_bresp      [4]
);

  function automatic logic [1:0] dec_oc(input logic [31:0] addr);
    case (soc_decode_slave(addr))
      3'(SLV_BOOTROM): return 2'd0;
      3'(SLV_SRAM):    return 2'd1;
      3'(SLV_CLINT), 3'(SLV_PLIC), 3'(SLV_UART), 3'(SLV_SYSCTRL): return 2'd2;
      default:         return 2'd3;
    endcase
  endfunction

  // Tier-2 Master ports: M0 = Core LSU MMIO, M1 = Core LLC On-Chip Downsizer
  logic [1:0]          oc_m_arvalid, oc_m_arready, oc_m_rvalid, oc_m_rready, oc_m_rlast, oc_m_arlock, oc_m_awlock;
  logic [1:0]          oc_m_awvalid, oc_m_awready, oc_m_wvalid, oc_m_wready, oc_m_wlast, oc_m_bvalid, oc_m_bready;
  logic [1:0]          oc_m_ar_slv [2], oc_m_aw_slv [2], oc_m_arburst [2], oc_m_awburst [2];
  logic [1:0]          oc_m_rresp [2], oc_m_bresp [2];
  logic [DDR_ID_W-1:0] oc_m_arid [2], oc_m_rid [2], oc_m_awid [2], oc_m_bid [2];
  logic [31:0]         oc_m_araddr [2], oc_m_awaddr [2];
  logic [7:0]          oc_m_arlen [2], oc_m_awlen [2], oc_m_wstrb [2];
  logic [2:0]          oc_m_arsize [2], oc_m_awsize [2], oc_m_arprot [2], oc_m_awprot [2];
  logic [3:0]          oc_m_arcache [2], oc_m_awcache [2], oc_m_arqos [2], oc_m_awqos [2];
  logic [3:0]          oc_m_arregion [2], oc_m_awregion [2];
  logic [63:0]         oc_m_rdata [2], oc_m_wdata [2];

  soc_xbar_sys #(.DDR_DATA_W(DDR_DATA_W), .DDR_ID_W(DDR_ID_W)) u_sys (
    .clk, .rst_n,
    .c_arvalid, .c_arready, .c_arid, .c_araddr, .c_arlen, .c_rvalid, .c_rready, .c_rid, .c_rdata,
    .c_awvalid, .c_awready, .c_awid, .c_awaddr, .c_awlen, .c_wvalid, .c_wready, .c_wdata, .c_wstrb, .c_wlast,
    .c_bvalid, .c_bready, .c_bid, .c_bresp,
    .ddr_arvalid, .ddr_arready, .ddr_arid, .ddr_araddr, .ddr_arlen, .ddr_arsize, .ddr_arburst,
    .ddr_arlock, .ddr_arcache, .ddr_arprot, .ddr_arqos, .ddr_arregion,
    .ddr_rvalid, .ddr_rready, .ddr_rid, .ddr_rdata, .ddr_rresp, .ddr_rlast,
    .ddr_awvalid, .ddr_awready, .ddr_awid, .ddr_awaddr, .ddr_awlen, .ddr_awsize, .ddr_awburst,
    .ddr_awlock, .ddr_awcache, .ddr_awprot, .ddr_awqos, .ddr_awregion,
    .ddr_wvalid, .ddr_wready, .ddr_wdata, .ddr_wstrb, .ddr_wlast,
    .ddr_bvalid, .ddr_bready, .ddr_bid, .ddr_bresp,
    .oc_arvalid(oc_m_arvalid[1]), .oc_arready(oc_m_arready[1]), .oc_arid(oc_m_arid[1]),
    .oc_araddr(oc_m_araddr[1]), .oc_arlen(oc_m_arlen[1]), .oc_arsize(oc_m_arsize[1]),
    .oc_arburst(oc_m_arburst[1]), .oc_arlock(oc_m_arlock[1]), .oc_arcache(oc_m_arcache[1]),
    .oc_arprot(oc_m_arprot[1]), .oc_arqos(oc_m_arqos[1]), .oc_arregion(oc_m_arregion[1]),
    .oc_rvalid(oc_m_rvalid[1]), .oc_rready(oc_m_rready[1]), .oc_rid(oc_m_rid[1]),
    .oc_rdata(oc_m_rdata[1]), .oc_rresp(oc_m_rresp[1]), .oc_rlast(oc_m_rlast[1]),
    .oc_awvalid(oc_m_awvalid[1]), .oc_awready(oc_m_awready[1]), .oc_awid(oc_m_awid[1]),
    .oc_awaddr(oc_m_awaddr[1]), .oc_awlen(oc_m_awlen[1]), .oc_awsize(oc_m_awsize[1]),
    .oc_awburst(oc_m_awburst[1]), .oc_awlock(oc_m_awlock[1]), .oc_awcache(oc_m_awcache[1]),
    .oc_awprot(oc_m_awprot[1]), .oc_awqos(oc_m_awqos[1]), .oc_awregion(oc_m_awregion[1]),
    .oc_wvalid(oc_m_wvalid[1]), .oc_wready(oc_m_wready[1]), .oc_wdata(oc_m_wdata[1]),
    .oc_wstrb(oc_m_wstrb[1]), .oc_wlast(oc_m_wlast[1]),
    .oc_bvalid(oc_m_bvalid[1]), .oc_bready(oc_m_bready[1]), .oc_bid(oc_m_bid[1]), .oc_bresp(oc_m_bresp[1])
  );

  assign oc_m_arvalid[0] = mmio_arvalid; assign mmio_arready = oc_m_arready[0];
  assign oc_m_arid[0]    = {{(DDR_ID_W-4){1'b0}}, mmio_arid};
  assign oc_m_araddr[0]  = mmio_araddr;  assign oc_m_arlen[0] = mmio_arlen; assign oc_m_arsize[0] = mmio_arsize;
  assign oc_m_arburst[0] = mmio_arburst; assign oc_m_arlock[0] = mmio_arlock; assign oc_m_arcache[0] = mmio_arcache;
  assign oc_m_arprot[0]  = mmio_arprot;  assign oc_m_arqos[0] = mmio_arqos; assign oc_m_arregion[0] = mmio_arregion;
  assign mmio_rvalid     = oc_m_rvalid[0]; assign oc_m_rready[0] = mmio_rready; assign mmio_rid = oc_m_rid[0][3:0];
  assign mmio_rdata      = oc_m_rdata[0];  assign mmio_rresp = oc_m_rresp[0];  assign mmio_rlast = oc_m_rlast[0];
  assign oc_m_awvalid[0] = mmio_awvalid; assign mmio_awready = oc_m_awready[0];
  assign oc_m_awid[0]    = {{(DDR_ID_W-4){1'b0}}, mmio_awid};
  assign oc_m_awaddr[0]  = mmio_awaddr;  assign oc_m_awlen[0] = mmio_awlen; assign oc_m_awsize[0] = mmio_awsize;
  assign oc_m_awburst[0] = mmio_awburst; assign oc_m_awlock[0] = mmio_awlock; assign oc_m_awcache[0] = mmio_awcache;
  assign oc_m_awprot[0]  = mmio_awprot;  assign oc_m_awqos[0] = mmio_awqos; assign oc_m_awregion[0] = mmio_awregion;
  assign oc_m_wvalid[0]  = mmio_wvalid;  assign mmio_wready = oc_m_wready[0]; assign oc_m_wdata[0] = mmio_wdata;
  assign oc_m_wstrb[0]   = mmio_wstrb;   assign oc_m_wlast[0] = mmio_wlast;
  assign mmio_bvalid     = oc_m_bvalid[0]; assign oc_m_bready[0] = mmio_bready;
  assign mmio_bid        = oc_m_bid[0][3:0]; assign mmio_bresp = oc_m_bresp[0];

  assign oc_m_ar_slv[0] = dec_oc(mmio_araddr); assign oc_m_aw_slv[0] = dec_oc(mmio_awaddr);
  assign oc_m_ar_slv[1] = dec_oc(oc_m_araddr[1]); assign oc_m_aw_slv[1] = dec_oc(oc_m_awaddr[1]);

  // Tier-2 Slave ports: 0=BootROM, 1=SRAM, 2=PeriphBridge
  logic [2:0]         oc_s_arvalid, oc_s_arready, oc_s_rvalid, oc_s_rready, oc_s_rlast, oc_s_arlock, oc_s_awlock;
  logic [2:0]         oc_s_awvalid, oc_s_awready, oc_s_wvalid, oc_s_wready, oc_s_wlast, oc_s_bvalid, oc_s_bready;
  logic [OC_ID_W-1:0] oc_s_arid [3], oc_s_rid [3], oc_s_awid [3], oc_s_bid [3];
  logic [31:0]        oc_s_araddr [3], oc_s_awaddr [3];
  logic [7:0]         oc_s_arlen [3], oc_s_awlen [3], oc_s_wstrb [3];
  logic [2:0]         oc_s_arsize [3], oc_s_awsize [3], oc_s_arprot [3], oc_s_awprot [3];
  logic [1:0]         oc_s_arburst [3], oc_s_awburst [3], oc_s_rresp [3], oc_s_bresp [3];
  logic [3:0]         oc_s_arcache [3], oc_s_awcache [3], oc_s_arqos [3], oc_s_awqos [3];
  logic [3:0]         oc_s_arregion [3], oc_s_awregion [3];
  logic [63:0]        oc_s_rdata [3], oc_s_wdata [3];

  soc_axi_xbar #(
    .NM(2), .NS(3), .DATA_W(64), .ADDR_W(32), .M_ID_W(DDR_ID_W), .M_IDX_W(1),
    .S_ID_W(OC_ID_W), .SLV_W(2), .MAX_RD(8), .MAX_WR(4)
  ) u_oc_xbar (
    .clk, .rst_n,
    .m_arvalid(oc_m_arvalid), .m_arready(oc_m_arready), .m_ar_slv(oc_m_ar_slv), .m_arid(oc_m_arid),
    .m_araddr(oc_m_araddr), .m_arlen(oc_m_arlen), .m_arsize(oc_m_arsize), .m_arburst(oc_m_arburst),
    .m_arlock(oc_m_arlock), .m_arcache(oc_m_arcache), .m_arprot(oc_m_arprot), .m_arqos(oc_m_arqos),
    .m_arregion(oc_m_arregion), .m_rvalid(oc_m_rvalid), .m_rready(oc_m_rready), .m_rid(oc_m_rid),
    .m_rdata(oc_m_rdata), .m_rresp(oc_m_rresp), .m_rlast(oc_m_rlast),
    .m_awvalid(oc_m_awvalid), .m_awready(oc_m_awready), .m_aw_slv(oc_m_aw_slv), .m_awid(oc_m_awid),
    .m_awaddr(oc_m_awaddr), .m_awlen(oc_m_awlen), .m_awsize(oc_m_awsize), .m_awburst(oc_m_awburst),
    .m_awlock(oc_m_awlock), .m_awcache(oc_m_awcache), .m_awprot(oc_m_awprot), .m_awqos(oc_m_awqos),
    .m_awregion(oc_m_awregion), .m_wvalid(oc_m_wvalid), .m_wready(oc_m_wready), .m_wdata(oc_m_wdata),
    .m_wstrb(oc_m_wstrb), .m_wlast(oc_m_wlast), .m_bvalid(oc_m_bvalid), .m_bready(oc_m_bready),
    .m_bid(oc_m_bid), .m_bresp(oc_m_bresp),
    .s_arvalid(oc_s_arvalid), .s_arready(oc_s_arready), .s_arid(oc_s_arid), .s_araddr(oc_s_araddr),
    .s_arlen(oc_s_arlen), .s_arsize(oc_s_arsize), .s_arburst(oc_s_arburst), .s_arlock(oc_s_arlock),
    .s_arcache(oc_s_arcache), .s_arprot(oc_s_arprot), .s_arqos(oc_s_arqos), .s_arregion(oc_s_arregion),
    .s_rvalid(oc_s_rvalid), .s_rready(oc_s_rready), .s_rid(oc_s_rid), .s_rdata(oc_s_rdata),
    .s_rresp(oc_s_rresp), .s_rlast(oc_s_rlast),
    .s_awvalid(oc_s_awvalid), .s_awready(oc_s_awready), .s_awid(oc_s_awid), .s_awaddr(oc_s_awaddr),
    .s_awlen(oc_s_awlen), .s_awsize(oc_s_awsize), .s_awburst(oc_s_awburst), .s_awlock(oc_s_awlock),
    .s_awcache(oc_s_awcache), .s_awprot(oc_s_awprot), .s_awqos(oc_s_awqos), .s_awregion(oc_s_awregion),
    .s_wvalid(oc_s_wvalid), .s_wready(oc_s_wready), .s_wdata(oc_s_wdata), .s_wstrb(oc_s_wstrb),
    .s_wlast(oc_s_wlast), .s_bvalid(oc_s_bvalid), .s_bready(oc_s_bready), .s_bid(oc_s_bid), .s_bresp(oc_s_bresp)
  );

  for (genvar s = 0; s < 2; s++) begin : g_mem_slv
    assign mem_arvalid[s] = oc_s_arvalid[s]; assign oc_s_arready[s] = mem_arready[s];
    assign mem_arid[s] = oc_s_arid[s]; assign mem_araddr[s] = oc_s_araddr[s]; assign mem_arlen[s] = oc_s_arlen[s];
    assign mem_arsize[s] = oc_s_arsize[s]; assign mem_arburst[s] = oc_s_arburst[s];
    assign mem_arlock[s] = oc_s_arlock[s]; assign mem_arcache[s] = oc_s_arcache[s];
    assign mem_arprot[s] = oc_s_arprot[s]; assign mem_arqos[s] = oc_s_arqos[s];
    assign mem_arregion[s] = oc_s_arregion[s];
    assign oc_s_rvalid[s] = mem_rvalid[s]; assign mem_rready[s] = oc_s_rready[s];
    assign oc_s_rid[s] = mem_rid[s]; assign oc_s_rdata[s] = mem_rdata[s];
    assign oc_s_rresp[s] = mem_rresp[s]; assign oc_s_rlast[s] = mem_rlast[s];
    assign mem_awvalid[s] = oc_s_awvalid[s]; assign oc_s_awready[s] = mem_awready[s];
    assign mem_awid[s] = oc_s_awid[s]; assign mem_awaddr[s] = oc_s_awaddr[s]; assign mem_awlen[s] = oc_s_awlen[s];
    assign mem_awsize[s] = oc_s_awsize[s]; assign mem_awburst[s] = oc_s_awburst[s];
    assign mem_awlock[s] = oc_s_awlock[s]; assign mem_awcache[s] = oc_s_awcache[s];
    assign mem_awprot[s] = oc_s_awprot[s]; assign mem_awqos[s] = oc_s_awqos[s];
    assign mem_awregion[s] = oc_s_awregion[s];
    assign mem_wvalid[s] = oc_s_wvalid[s]; assign oc_s_wready[s] = mem_wready[s];
    assign mem_wdata[s] = oc_s_wdata[s]; assign mem_wstrb[s] = oc_s_wstrb[s]; assign mem_wlast[s] = oc_s_wlast[s];
    assign oc_s_bvalid[s] = mem_bvalid[s]; assign mem_bready[s] = oc_s_bready[s];
    assign oc_s_bid[s] = mem_bid[s]; assign oc_s_bresp[s] = mem_bresp[s];
  end

  soc_axi_to_lite #(.ID_W(OC_ID_W), .NP(4)) u_periph_bridge (
    .clk, .rst_n,
    .s_arvalid(oc_s_arvalid[2]), .s_arready(oc_s_arready[2]), .s_arid(oc_s_arid[2]), .s_araddr(oc_s_araddr[2]),
    .s_arlen(oc_s_arlen[2]), .s_arsize(oc_s_arsize[2]), .s_arburst(oc_s_arburst[2]), .s_arlock(oc_s_arlock[2]),
    .s_arcache(oc_s_arcache[2]), .s_arprot(oc_s_arprot[2]), .s_arqos(oc_s_arqos[2]), .s_arregion(oc_s_arregion[2]),
    .s_rvalid(oc_s_rvalid[2]), .s_rready(oc_s_rready[2]), .s_rid(oc_s_rid[2]), .s_rdata(oc_s_rdata[2]),
    .s_rresp(oc_s_rresp[2]), .s_rlast(oc_s_rlast[2]),
    .s_awvalid(oc_s_awvalid[2]), .s_awready(oc_s_awready[2]), .s_awid(oc_s_awid[2]), .s_awaddr(oc_s_awaddr[2]),
    .s_awlen(oc_s_awlen[2]), .s_awsize(oc_s_awsize[2]), .s_awburst(oc_s_awburst[2]), .s_awlock(oc_s_awlock[2]),
    .s_awcache(oc_s_awcache[2]), .s_awprot(oc_s_awprot[2]), .s_awqos(oc_s_awqos[2]), .s_awregion(oc_s_awregion[2]),
    .s_wvalid(oc_s_wvalid[2]), .s_wready(oc_s_wready[2]), .s_wdata(oc_s_wdata[2]), .s_wstrb(oc_s_wstrb[2]),
    .s_wlast(oc_s_wlast[2]), .s_bvalid(oc_s_bvalid[2]), .s_bready(oc_s_bready[2]), .s_bid(oc_s_bid[2]),
    .s_bresp(oc_s_bresp[2]),
    .p_arvalid, .p_arready, .p_araddr, .p_rvalid, .p_rready, .p_rdata, .p_rresp,
    .p_awvalid, .p_awready, .p_awaddr, .p_wvalid, .p_wready, .p_wdata, .p_wstrb, .p_bvalid, .p_bready, .p_bresp
  );

`ifndef SYNTHESIS
  soc_axi_checker #(.DATA_W(64), .ID_W(4), .NAME("core_mmio_axi4")) u_chk_mmio (
    .clk, .rst_n,
    .arvalid(mmio_arvalid), .arready(mmio_arready), .arid(mmio_arid), .araddr(mmio_araddr), .arlen(mmio_arlen),
    .arsize(mmio_arsize), .arburst(mmio_arburst), .arlock(mmio_arlock), .arcache(mmio_arcache),
    .arprot(mmio_arprot), .arqos(mmio_arqos), .arregion(mmio_arregion),
    .rvalid(mmio_rvalid), .rready(mmio_rready), .rid(mmio_rid), .rdata(mmio_rdata),
    .rresp(mmio_rresp), .rlast(mmio_rlast),
    .awvalid(mmio_awvalid), .awready(mmio_awready), .awid(mmio_awid), .awaddr(mmio_awaddr), .awlen(mmio_awlen),
    .awsize(mmio_awsize), .awburst(mmio_awburst), .awlock(mmio_awlock), .awcache(mmio_awcache),
    .awprot(mmio_awprot), .awqos(mmio_awqos), .awregion(mmio_awregion),
    .wvalid(mmio_wvalid), .wready(mmio_wready), .wdata(mmio_wdata), .wstrb(mmio_wstrb), .wlast(mmio_wlast),
    .bvalid(mmio_bvalid), .bready(mmio_bready), .bid(mmio_bid), .bresp(mmio_bresp)
  );
  soc_axi_checker #(.DATA_W(64), .ID_W(OC_ID_W), .NAME("oc_sram_axi4")) u_chk_sram (
    .clk, .rst_n,
    .arvalid(mem_arvalid[1]), .arready(mem_arready[1]), .arid(mem_arid[1]), .araddr(mem_araddr[1]),
    .arlen(mem_arlen[1]), .arsize(mem_arsize[1]), .arburst(mem_arburst[1]), .arlock(mem_arlock[1]),
    .arcache(mem_arcache[1]), .arprot(mem_arprot[1]), .arqos(mem_arqos[1]), .arregion(mem_arregion[1]),
    .rvalid(mem_rvalid[1]), .rready(mem_rready[1]), .rid(mem_rid[1]), .rdata(mem_rdata[1]),
    .rresp(mem_rresp[1]), .rlast(mem_rlast[1]),
    .awvalid(mem_awvalid[1]), .awready(mem_awready[1]), .awid(mem_awid[1]), .awaddr(mem_awaddr[1]),
    .awlen(mem_awlen[1]), .awsize(mem_awsize[1]), .awburst(mem_awburst[1]), .awlock(mem_awlock[1]),
    .awcache(mem_awcache[1]), .awprot(mem_awprot[1]), .awqos(mem_awqos[1]), .awregion(mem_awregion[1]),
    .wvalid(mem_wvalid[1]), .wready(mem_wready[1]), .wdata(mem_wdata[1]), .wstrb(mem_wstrb[1]), .wlast(mem_wlast[1]),
    .bvalid(mem_bvalid[1]), .bready(mem_bready[1]), .bid(mem_bid[1]), .bresp(mem_bresp[1])
  );
`endif

  /* verilator lint_off UNUSEDSIGNAL */
  logic [5:0] unused_mmio_id_hi;
  assign unused_mmio_id_hi = {oc_m_rid[0][DDR_ID_W-1:4], oc_m_bid[0][DDR_ID_W-1:4]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
