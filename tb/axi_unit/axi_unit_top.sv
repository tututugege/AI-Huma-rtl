// Ref: docs/modules/soc_axi.md  Standalone AXI4 fabric + slaves verification top
`default_nettype none

module axi_unit_top import soc_axi_pkg::*; import soc_pkg::*; #(
  parameter int DDR_DATA_W = 64,
  parameter int DDR_ID_W   = 7,
  parameter int OC_ID_W    = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // M0: Core LLC 256-bit AXI4 port
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
  // M1: Core MMIO 64-bit Full-AXI4 port
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
  // External DDR AXI4 port
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
  input  logic [1:0]              ddr_bresp
);

  logic [1:0]         mem_arvalid, mem_arready, mem_rvalid, mem_rready, mem_rlast, mem_arlock, mem_awlock;
  logic [1:0]         mem_awvalid, mem_awready, mem_wvalid, mem_wready, mem_wlast, mem_bvalid, mem_bready;
  logic [OC_ID_W-1:0] mem_arid [2], mem_rid [2], mem_awid [2], mem_bid [2];
  logic [31:0]        mem_araddr [2], mem_awaddr [2];
  logic [7:0]         mem_arlen [2], mem_awlen [2], mem_wstrb [2];
  logic [2:0]         mem_arsize [2], mem_awsize [2], mem_arprot [2], mem_awprot [2];
  logic [1:0]         mem_arburst [2], mem_awburst [2], mem_rresp [2], mem_bresp [2];
  logic [3:0]         mem_arcache [2], mem_awcache [2], mem_arqos [2], mem_awqos [2];
  logic [3:0]         mem_arregion [2], mem_awregion [2];
  logic [63:0]        mem_rdata [2], mem_wdata [2];

  logic [3:0]  p_arvalid, p_arready, p_rvalid, p_rready;
  logic [3:0]  p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
  logic [31:0] p_araddr [4], p_awaddr [4];
  logic [63:0] p_rdata [4], p_wdata [4];
  logic [7:0]  p_wstrb [4];
  logic [1:0]  p_rresp [4], p_bresp [4];

  soc_xbar #(.DDR_DATA_W(DDR_DATA_W), .DDR_ID_W(DDR_ID_W), .OC_ID_W(OC_ID_W)) u_xbar (.*);

  soc_bootrom #(.ID_W(OC_ID_W)) u_bootrom (
    .clk, .rst_n,
    .s_arvalid(mem_arvalid[0]), .s_arready(mem_arready[0]), .s_arid(mem_arid[0]), .s_araddr(mem_araddr[0]),
    .s_arlen(mem_arlen[0]), .s_arsize(mem_arsize[0]), .s_arburst(mem_arburst[0]), .s_arlock(mem_arlock[0]),
    .s_arcache(mem_arcache[0]), .s_arprot(mem_arprot[0]), .s_arqos(mem_arqos[0]), .s_arregion(mem_arregion[0]),
    .s_rvalid(mem_rvalid[0]), .s_rready(mem_rready[0]), .s_rid(mem_rid[0]), .s_rdata(mem_rdata[0]),
    .s_rresp(mem_rresp[0]), .s_rlast(mem_rlast[0]),
    .s_awvalid(mem_awvalid[0]), .s_awready(mem_awready[0]), .s_awid(mem_awid[0]), .s_awaddr(mem_awaddr[0]),
    .s_awlen(mem_awlen[0]), .s_awsize(mem_awsize[0]), .s_awburst(mem_awburst[0]), .s_awlock(mem_awlock[0]),
    .s_awcache(mem_awcache[0]), .s_awprot(mem_awprot[0]), .s_awqos(mem_awqos[0]), .s_awregion(mem_awregion[0]),
    .s_wvalid(mem_wvalid[0]), .s_wready(mem_wready[0]), .s_wdata(mem_wdata[0]), .s_wstrb(mem_wstrb[0]),
    .s_wlast(mem_wlast[0]), .s_bvalid(mem_bvalid[0]), .s_bready(mem_bready[0]), .s_bid(mem_bid[0]),
    .s_bresp(mem_bresp[0])
  );

  soc_sram #(.ID_W(OC_ID_W)) u_sram (
    .clk, .rst_n,
    .s_arvalid(mem_arvalid[1]), .s_arready(mem_arready[1]), .s_arid(mem_arid[1]), .s_araddr(mem_araddr[1]),
    .s_arlen(mem_arlen[1]), .s_arsize(mem_arsize[1]), .s_arburst(mem_arburst[1]), .s_arlock(mem_arlock[1]),
    .s_arcache(mem_arcache[1]), .s_arprot(mem_arprot[1]), .s_arqos(mem_arqos[1]), .s_arregion(mem_arregion[1]),
    .s_rvalid(mem_rvalid[1]), .s_rready(mem_rready[1]), .s_rid(mem_rid[1]), .s_rdata(mem_rdata[1]),
    .s_rresp(mem_rresp[1]), .s_rlast(mem_rlast[1]),
    .s_awvalid(mem_awvalid[1]), .s_awready(mem_awready[1]), .s_awid(mem_awid[1]), .s_awaddr(mem_awaddr[1]),
    .s_awlen(mem_awlen[1]), .s_awsize(mem_awsize[1]), .s_awburst(mem_awburst[1]), .s_awlock(mem_awlock[1]),
    .s_awcache(mem_awcache[1]), .s_awprot(mem_awprot[1]), .s_awqos(mem_awqos[1]), .s_awregion(mem_awregion[1]),
    .s_wvalid(mem_wvalid[1]), .s_wready(mem_wready[1]), .s_wdata(mem_wdata[1]), .s_wstrb(mem_wstrb[1]),
    .s_wlast(mem_wlast[1]), .s_bvalid(mem_bvalid[1]), .s_bready(mem_bready[1]), .s_bid(mem_bid[1]),
    .s_bresp(mem_bresp[1])
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic mtip_u, msip_u, meip_u, seip_u, uart_irq_u, uart_txd_u, sw_rst_u;
  logic [63:0] core_ctl_u;
  /* verilator lint_on UNUSEDSIGNAL */
  soc_clint u_clint (
    .clk, .rst_n, .rtc_tick(1'b0), .mtip(mtip_u), .msip(msip_u),
    .s_arvalid(p_arvalid[0]), .s_arready(p_arready[0]), .s_araddr(p_araddr[0]),
    .s_rvalid(p_rvalid[0]), .s_rready(p_rready[0]), .s_rdata(p_rdata[0]), .s_rresp(p_rresp[0]),
    .s_awvalid(p_awvalid[0]), .s_awready(p_awready[0]), .s_awaddr(p_awaddr[0]),
    .s_wvalid(p_wvalid[0]), .s_wready(p_wready[0]), .s_wdata(p_wdata[0]), .s_wstrb(p_wstrb[0]),
    .s_bvalid(p_bvalid[0]), .s_bready(p_bready[0]), .s_bresp(p_bresp[0])
  );
  soc_plic u_plic (
    .clk, .rst_n, .irq_src(8'd0), .meip(meip_u), .seip(seip_u),
    .s_arvalid(p_arvalid[1]), .s_arready(p_arready[1]), .s_araddr(p_araddr[1]),
    .s_rvalid(p_rvalid[1]), .s_rready(p_rready[1]), .s_rdata(p_rdata[1]), .s_rresp(p_rresp[1]),
    .s_awvalid(p_awvalid[1]), .s_awready(p_awready[1]), .s_awaddr(p_awaddr[1]),
    .s_wvalid(p_wvalid[1]), .s_wready(p_wready[1]), .s_wdata(p_wdata[1]), .s_wstrb(p_wstrb[1]),
    .s_bvalid(p_bvalid[1]), .s_bready(p_bready[1]), .s_bresp(p_bresp[1])
  );
  soc_uart u_uart (
    .clk, .rst_n, .uart_rxd(1'b1), .uart_txd(uart_txd_u), .irq_out(uart_irq_u),
    .s_arvalid(p_arvalid[2]), .s_arready(p_arready[2]), .s_araddr(p_araddr[2]),
    .s_rvalid(p_rvalid[2]), .s_rready(p_rready[2]), .s_rdata(p_rdata[2]), .s_rresp(p_rresp[2]),
    .s_awvalid(p_awvalid[2]), .s_awready(p_awready[2]), .s_awaddr(p_awaddr[2]),
    .s_wvalid(p_wvalid[2]), .s_wready(p_wready[2]), .s_wdata(p_wdata[2]), .s_wstrb(p_wstrb[2]),
    .s_bvalid(p_bvalid[2]), .s_bready(p_bready[2]), .s_bresp(p_bresp[2])
  );
  soc_sysctrl u_sysctrl (
    .clk, .rst_n, .boot_mode(2'b00), .sw_rst_req(sw_rst_u), .core_ctl_out(core_ctl_u),
    .s_arvalid(p_arvalid[3]), .s_arready(p_arready[3]), .s_araddr(p_araddr[3]),
    .s_rvalid(p_rvalid[3]), .s_rready(p_rready[3]), .s_rdata(p_rdata[3]), .s_rresp(p_rresp[3]),
    .s_awvalid(p_awvalid[3]), .s_awready(p_awready[3]), .s_awaddr(p_awaddr[3]),
    .s_wvalid(p_wvalid[3]), .s_wready(p_wready[3]), .s_wdata(p_wdata[3]), .s_wstrb(p_wstrb[3]),
    .s_bvalid(p_bvalid[3]), .s_bready(p_bready[3]), .s_bresp(p_bresp[3])
  );

endmodule
`default_nettype wire
