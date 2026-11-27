// Ref: docs/modules/chip_top.md  Tapeout-oriented AI-Huma SoC top level (Real Full-AXI4 fabric)
`default_nettype none

// Real tapeout-oriented SoC top level:
//   CRG + core_top + mem_top(EXT_MMIO_EN=1) + 2-tier Full-AXI4 soc_xbar (with Downsizer + RegSlices)
//   + Native AXI4 BootROM & 64 KiB SRAM + AXI4-to-Lite Bridge + CLINT + PLIC + UART16550A + SysCtrl.
// Exposes only realistic chip pins with complete ARM IHI 0022E AXI4 DDR master port (default DDR_DATA_W=64).
module chip_top import ttg_cfg_pkg::*; import tlb_mmu_pkg::*; import soc_pkg::*; #(
  parameter bit PF_EN      = 1'b1,
  parameter int DDR_DATA_W = 64,    // 64 (8-beat 64B line), 128 (4-beat), or 256 (2-beat)
  parameter int DDR_ID_W   = 7
) (
  // Clocks, Reset, DFT, Boot straps
  input  logic                    clk_core,
  input  logic                    clk_rtc,
  input  logic                    por_rst_n,
  input  logic                    dft_test_mode,
  input  logic                    dft_scan_en,
  input  logic [1:0]              boot_mode,
  // Real serial UART16550A pins
  input  logic                    uart_rxd,
  output logic                    uart_txd,
  // External IRQ pins (PLIC sources 2..8; source 1 is internal UART)
  input  logic [PLIC_NUM_SRC-2:0] ext_irq,
  // Complete ARM IHI 0022E Standard AXI4 External DDR Master port (timing-isolated via soc_axi_reg_slice)
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

  localparam int OC_ID_W = DDR_ID_W + 1;

  // ---- CRG ----
  logic sys_rst_n, rtc_tick, sw_rst_req;
  soc_crg u_crg (
    .clk_core, .clk_rtc, .por_rst_n, .ext_ndmreset(1'b0), .sw_rst_req,
    .dft_test_mode, .dft_scan_en, .sys_rst_n, .rtc_tick
  );

  // ---- Interrupts from CLINT / PLIC ----
  logic clint_mtip, clint_msip, plic_meip, plic_seip, uart_irq;

  // ---- Core <-> MemTop internal wires ----
  logic mem_req_ready, mem_req_accepted, mem_resp_valid, mem_req_valid, mem_req_bypass, mem_resp_ready;
  logic [3:0]  mem_req_accepted_id, mem_resp_id, mem_req_id;
  logic [31:0] mem_req_addr, mem_resp_data [ICACHE_WORD_NUM], dc_resp_data, dc_req_addr;
  logic [7:0]  mem_req_total_size;
  logic dc_resp_valid, dc_resp_retry, dc_resp_miss, dc_req_valid;
  logic itlb_walk_req_ready, itlb_walk_resp_valid, itlb_walk_resp_fault;
  logic itlb_walk_req_valid, itlb_walk_resp_consumed, itlb_walk_flush;
  logic [VPN_W-1:0]  itlb_walk_resp_vpn, itlb_walk_req_vpn;
  logic [PPN_W-1:0]  itlb_walk_resp_leaf_ppn;
  logic [PERM_W-1:0] itlb_walk_resp_leaf_perm;
  logic [LVL_W-1:0]  itlb_walk_resp_leaf_level;
  logic [21:0]       itlb_walk_req_root_ppn;
  logic dtlb_walk_req_ready, dtlb_walk_resp_valid, dtlb_walk_resp_fault;
  logic dtlb_walk_req_valid, dtlb_walk_resp_consumed, dtlb_walk_flush;
  logic [VPN_W-1:0]  dtlb_walk_resp_vpn, dtlb_walk_req_vpn;
  logic [PPN_W-1:0]  dtlb_walk_resp_leaf_ppn;
  logic [PERM_W-1:0] dtlb_walk_resp_leaf_perm;
  logic [LVL_W-1:0]  dtlb_walk_resp_leaf_level;
  logic [21:0]       dtlb_walk_req_root_ppn;
  logic [XLEN_BITS-1:0] dcache2lsu_load_resps_data [LSU_LDU_COUNT];
  logic [1:0]  dcache2lsu_load_resps_replay [LSU_LDU_COUNT];
  logic [31:0] dcache2lsu_load_resps_req_id [LSU_LDU_COUNT];
  logic        dcache2lsu_load_resps_valid [LSU_LDU_COUNT];
  logic        dcache2lsu_load_retry_busy [LSU_LDU_COUNT], dcache2lsu_store_retry_busy [LSU_STA_COUNT];
  logic        dcache2lsu_mshr_fill;
  logic [25:0] dcache2lsu_mshr_fill_line;
  logic [1:0]  dcache2lsu_store_resps_replay [LSU_STA_COUNT];
  logic [31:0] dcache2lsu_store_resps_req_id [LSU_STA_COUNT];
  logic        dcache2lsu_store_resps_valid [LSU_STA_COUNT];
  logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT], lsu2dcache_load_ports_pc [LSU_LDU_COUNT];
  logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT];
  logic        lsu2dcache_load_ports_replay [LSU_LDU_COUNT], lsu2dcache_load_ports_valid [LSU_LDU_COUNT];
  logic [38:0] lsu2dcache_load_ports_va [LSU_LDU_COUNT];
  logic [LSU_LDU_COUNT-1:0] pf_xq_v, pf_xq_llc, pf_xans_v, pf_xans_llc;
  logic [38:0] pf_xq_va [LSU_LDU_COUNT];
  logic [2:0]  pf_xq_pop;
  logic [25:0] pf_xans_line [LSU_LDU_COUNT];
  logic [31:0] lsu2dcache_store_ports_addr [LSU_STA_COUNT];
  logic [XLEN_BITS-1:0] lsu2dcache_store_ports_data [LSU_STA_COUNT];
  logic [5:0]  lsu2dcache_store_ports_req_id [LSU_STA_COUNT];
  logic [DST_STRB_W-1:0] lsu2dcache_store_ports_strb [LSU_STA_COUNT];
  logic [DST_L2_W-1:0]   lsu2dcache_store_ports_l2 [LSU_STA_COUNT];
  logic        lsu2dcache_store_ports_valid [LSU_STA_COUNT];
  logic        peripheral_req_is_mmio, peripheral_req_wen;
  logic [31:0] peripheral_req_mmio_addr;
  logic [2:0]  peripheral_req_mmio_fun3;
  logic [XLEN_BITS-1:0] peripheral_req_mmio_wdata;
  logic        peripheral_resp_is_mmio, peripheral_resp_ready;
  logic [XLEN_BITS-1:0] peripheral_resp_mmio_rdata;
  logic        rob_bcast_fence;

  // Core retirement wires (kept internal; TB can bind SVA/Difftest hierarchically without chip pins)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN_BITS-1:0] ftq_commit_info_resp_pc [COMMIT_WIDTH];
  logic [XLEN_BITS-1:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH];
  logic        out_mispred, rob_bcast_exception, rob_bcast_fence_i, rob_bcast_flush, rob_bcast_mret, rob_bcast_sret;
  logic [XLEN_BITS-1:0] out_redirect_pc, rob_bcast_pc;
  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_br_taken, rob_commit_commit_entry_uop_dest_en;
  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_inst;
  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_load;
  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_store;
  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_rob_flag, rob_commit_commit_entry_uop_stq_flag;
  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid;
  logic [5:0]  rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH];
  logic [ROB_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_rob_idx [COMMIT_WIDTH];
  logic [5:0]  rob_commit_commit_entry_uop_stq_idx [COMMIT_WIDTH];
  logic [4:0]  rob_commit_commit_entry_uop_type [COMMIT_WIDTH];
  logic        phase0, env_rd_en;
  logic [31:0] env_rd_addr;
  logic [2:0]  env_rd_func3;
  logic [63:0] sysctrl_core_ctl;
  /* verilator lint_on UNUSEDSIGNAL */

  // Core <-> Xbar buses
  logic         c_arvalid, c_arready, c_rvalid, c_rready, c_awvalid, c_awready, c_wvalid, c_wready, c_wlast;
  logic         c_bvalid, c_bready;
  logic [5:0]   c_arid, c_rid, c_awid, c_bid;
  logic [31:0]  c_araddr, c_awaddr, c_wstrb;
  logic [7:0]   c_arlen, c_awlen;
  logic [255:0] c_rdata, c_wdata;
  logic [1:0]   c_bresp;

  logic         mmio_arvalid, mmio_arready, mmio_rvalid, mmio_rready, mmio_rlast, mmio_arlock, mmio_awlock;
  logic         mmio_awvalid, mmio_awready, mmio_wvalid, mmio_wready, mmio_wlast, mmio_bvalid, mmio_bready;
  logic [3:0]   mmio_arid, mmio_rid, mmio_awid, mmio_bid, mmio_arcache, mmio_awcache;
  logic [3:0]   mmio_arqos, mmio_awqos, mmio_arregion, mmio_awregion;
  logic [31:0]  mmio_araddr, mmio_awaddr;
  logic [7:0]   mmio_arlen, mmio_awlen, mmio_wstrb;
  logic [2:0]   mmio_arsize, mmio_awsize, mmio_arprot, mmio_awprot;
  logic [1:0]   mmio_arburst, mmio_awburst, mmio_rresp, mmio_bresp;
  logic [63:0]  mmio_rdata, mmio_wdata;

  core_top u_core (
    .clk(clk_core), .rst_n(sys_rst_n),
    .interrupt_inject_software_irq_pending(clint_msip),
    .interrupt_inject_software_irq_pending_valid(1'b1),
    .interrupt_inject_external_irq_pending(plic_meip),
    .interrupt_inject_external_irq_pending_valid(1'b1),
    .interrupt_inject_supervisor_external_irq_pending(plic_seip),
    .interrupt_inject_supervisor_external_irq_pending_valid(1'b1),
    .interrupt_inject_timer_irq_pending(clint_mtip),
    .interrupt_inject_timer_irq_pending_valid(1'b1),
    .*
  );

  mem_top #(.PF_EN(PF_EN), .EXT_MMIO_EN(1'b1)) u_mem (
    .clk(clk_core), .rst_n(sys_rst_n),
    .env_modeled(1'b0), .env_rdata(64'd0),
    .d_arvalid(c_arvalid), .d_arready(c_arready), .d_arid(c_arid), .d_araddr(c_araddr), .d_arlen(c_arlen),
    .d_rvalid(c_rvalid), .d_rready(c_rready), .d_rid(c_rid), .d_rdata(c_rdata),
    .d_awvalid(c_awvalid), .d_awready(c_awready), .d_awid(c_awid), .d_awaddr(c_awaddr), .d_awlen(c_awlen),
    .d_wvalid(c_wvalid), .d_wready(c_wready), .d_wdata(c_wdata), .d_wstrb(c_wstrb), .d_wlast(c_wlast),
    .d_bvalid(c_bvalid), .d_bready(c_bready), .d_bid(c_bid), .d_bresp(c_bresp),
    .*
  );

  // ---- On-chip Full-AXI4 memory slaves: 0=BootROM, 1=SRAM ----
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

  // ---- On-chip AXI4-Lite peripheral slaves: 0=CLINT, 1=PLIC, 2=UART, 3=SysCtrl ----
  logic [3:0]  p_arvalid, p_arready, p_rvalid, p_rready;
  logic [3:0]  p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
  logic [31:0] p_araddr [4], p_awaddr [4];
  logic [63:0] p_rdata  [4], p_wdata  [4];
  logic [7:0]  p_wstrb  [4];
  logic [1:0]  p_rresp  [4], p_bresp  [4];

  soc_xbar #(.DDR_DATA_W(DDR_DATA_W), .DDR_ID_W(DDR_ID_W), .OC_ID_W(OC_ID_W)) u_xbar (
    .clk(clk_core), .rst_n(sys_rst_n),
    .c_arvalid, .c_arready, .c_arid, .c_araddr, .c_arlen,
    .c_rvalid, .c_rready, .c_rid, .c_rdata,
    .c_awvalid, .c_awready, .c_awid, .c_awaddr, .c_awlen,
    .c_wvalid, .c_wready, .c_wdata, .c_wstrb, .c_wlast,
    .c_bvalid, .c_bready, .c_bid, .c_bresp,
    .mmio_arvalid, .mmio_arready, .mmio_arid, .mmio_araddr, .mmio_arlen, .mmio_arsize, .mmio_arburst,
    .mmio_arlock, .mmio_arcache, .mmio_arprot, .mmio_arqos, .mmio_arregion,
    .mmio_rvalid, .mmio_rready, .mmio_rid, .mmio_rdata, .mmio_rresp, .mmio_rlast,
    .mmio_awvalid, .mmio_awready, .mmio_awid, .mmio_awaddr, .mmio_awlen, .mmio_awsize, .mmio_awburst,
    .mmio_awlock, .mmio_awcache, .mmio_awprot, .mmio_awqos, .mmio_awregion,
    .mmio_wvalid, .mmio_wready, .mmio_wdata, .mmio_wstrb, .mmio_wlast,
    .mmio_bvalid, .mmio_bready, .mmio_bid, .mmio_bresp,
    .ddr_arvalid, .ddr_arready, .ddr_arid, .ddr_araddr, .ddr_arlen, .ddr_arsize, .ddr_arburst,
    .ddr_arlock, .ddr_arcache, .ddr_arprot, .ddr_arqos, .ddr_arregion,
    .ddr_rvalid, .ddr_rready, .ddr_rid, .ddr_rdata, .ddr_rresp, .ddr_rlast,
    .ddr_awvalid, .ddr_awready, .ddr_awid, .ddr_awaddr, .ddr_awlen, .ddr_awsize, .ddr_awburst,
    .ddr_awlock, .ddr_awcache, .ddr_awprot, .ddr_awqos, .ddr_awregion,
    .ddr_wvalid, .ddr_wready, .ddr_wdata, .ddr_wstrb, .ddr_wlast,
    .ddr_bvalid, .ddr_bready, .ddr_bid, .ddr_bresp,
    .mem_arvalid, .mem_arready, .mem_arid, .mem_araddr, .mem_arlen, .mem_arsize, .mem_arburst,
    .mem_arlock, .mem_arcache, .mem_arprot, .mem_arqos, .mem_arregion,
    .mem_rvalid, .mem_rready, .mem_rid, .mem_rdata, .mem_rresp, .mem_rlast,
    .mem_awvalid, .mem_awready, .mem_awid, .mem_awaddr, .mem_awlen, .mem_awsize, .mem_awburst,
    .mem_awlock, .mem_awcache, .mem_awprot, .mem_awqos, .mem_awregion,
    .mem_wvalid, .mem_wready, .mem_wdata, .mem_wstrb, .mem_wlast,
    .mem_bvalid, .mem_bready, .mem_bid, .mem_bresp,
    .p_arvalid, .p_arready, .p_araddr, .p_rvalid, .p_rready, .p_rdata, .p_rresp,
    .p_awvalid, .p_awready, .p_awaddr, .p_wvalid, .p_wready, .p_wdata, .p_wstrb,
    .p_bvalid, .p_bready, .p_bresp
  );

  soc_bootrom #(.ID_W(OC_ID_W)) u_bootrom (
    .clk(clk_core), .rst_n(sys_rst_n),
    .s_arvalid(mem_arvalid[0]), .s_arready(mem_arready[0]), .s_arid(mem_arid[0]), .s_araddr(mem_araddr[0]),
    .s_arlen(mem_arlen[0]), .s_arsize(mem_arsize[0]), .s_arburst(mem_arburst[0]), .s_arlock(mem_arlock[0]),
    .s_arcache(mem_arcache[0]), .s_arprot(mem_arprot[0]), .s_arqos(mem_arqos[0]), .s_arregion(mem_arregion[0]),
    .s_rvalid(mem_rvalid[0]), .s_rready(mem_rready[0]), .s_rid(mem_rid[0]), .s_rdata(mem_rdata[0]),
    .s_rresp(mem_rresp[0]), .s_rlast(mem_rlast[0]),
    .s_awvalid(mem_awvalid[0]), .s_awready(mem_awready[0]), .s_awid(mem_awid[0]), .s_awaddr(mem_awaddr[0]),
    .s_awlen(mem_awlen[0]), .s_awsize(mem_awsize[0]), .s_awburst(mem_awburst[0]), .s_awlock(mem_awlock[0]),
    .s_awcache(mem_awcache[0]), .s_awprot(mem_awprot[0]), .s_awqos(mem_awqos[0]), .s_awregion(mem_awregion[0]),
    .s_wvalid(mem_wvalid[0]), .s_wready(mem_wready[0]), .s_wdata(mem_wdata[0]), .s_wstrb(mem_wstrb[0]),
    .s_wlast(mem_wlast[0]),
    .s_bvalid(mem_bvalid[0]), .s_bready(mem_bready[0]), .s_bid(mem_bid[0]), .s_bresp(mem_bresp[0])
  );

  soc_sram #(.ID_W(OC_ID_W)) u_sram (
    .clk(clk_core), .rst_n(sys_rst_n),
    .s_arvalid(mem_arvalid[1]), .s_arready(mem_arready[1]), .s_arid(mem_arid[1]), .s_araddr(mem_araddr[1]),
    .s_arlen(mem_arlen[1]), .s_arsize(mem_arsize[1]), .s_arburst(mem_arburst[1]), .s_arlock(mem_arlock[1]),
    .s_arcache(mem_arcache[1]), .s_arprot(mem_arprot[1]), .s_arqos(mem_arqos[1]), .s_arregion(mem_arregion[1]),
    .s_rvalid(mem_rvalid[1]), .s_rready(mem_rready[1]), .s_rid(mem_rid[1]), .s_rdata(mem_rdata[1]),
    .s_rresp(mem_rresp[1]), .s_rlast(mem_rlast[1]),
    .s_awvalid(mem_awvalid[1]), .s_awready(mem_awready[1]), .s_awid(mem_awid[1]), .s_awaddr(mem_awaddr[1]),
    .s_awlen(mem_awlen[1]), .s_awsize(mem_awsize[1]), .s_awburst(mem_awburst[1]), .s_awlock(mem_awlock[1]),
    .s_awcache(mem_awcache[1]), .s_awprot(mem_awprot[1]), .s_awqos(mem_awqos[1]), .s_awregion(mem_awregion[1]),
    .s_wvalid(mem_wvalid[1]), .s_wready(mem_wready[1]), .s_wdata(mem_wdata[1]), .s_wstrb(mem_wstrb[1]),
    .s_wlast(mem_wlast[1]),
    .s_bvalid(mem_bvalid[1]), .s_bready(mem_bready[1]), .s_bid(mem_bid[1]), .s_bresp(mem_bresp[1])
  );

  soc_clint u_clint (
    .clk(clk_core), .rst_n(sys_rst_n), .rtc_tick, .mtip(clint_mtip), .msip(clint_msip),
    .s_arvalid(p_arvalid[0]), .s_arready(p_arready[0]), .s_araddr(p_araddr[0]),
    .s_rvalid(p_rvalid[0]),   .s_rready(p_rready[0]),   .s_rdata(p_rdata[0]),   .s_rresp(p_rresp[0]),
    .s_awvalid(p_awvalid[0]), .s_awready(p_awready[0]), .s_awaddr(p_awaddr[0]),
    .s_wvalid(p_wvalid[0]),   .s_wready(p_wready[0]),   .s_wdata(p_wdata[0]),   .s_wstrb(p_wstrb[0]),
    .s_bvalid(p_bvalid[0]),   .s_bready(p_bready[0]),   .s_bresp(p_bresp[0])
  );

  soc_plic u_plic (
    .clk(clk_core), .rst_n(sys_rst_n), .irq_src({ext_irq, uart_irq}), .meip(plic_meip), .seip(plic_seip),
    .s_arvalid(p_arvalid[1]), .s_arready(p_arready[1]), .s_araddr(p_araddr[1]),
    .s_rvalid(p_rvalid[1]),   .s_rready(p_rready[1]),   .s_rdata(p_rdata[1]),   .s_rresp(p_rresp[1]),
    .s_awvalid(p_awvalid[1]), .s_awready(p_awready[1]), .s_awaddr(p_awaddr[1]),
    .s_wvalid(p_wvalid[1]),   .s_wready(p_wready[1]),   .s_wdata(p_wdata[1]),   .s_wstrb(p_wstrb[1]),
    .s_bvalid(p_bvalid[1]),   .s_bready(p_bready[1]),   .s_bresp(p_bresp[1])
  );

  soc_uart u_uart (
    .clk(clk_core), .rst_n(sys_rst_n), .uart_rxd, .uart_txd, .irq_out(uart_irq),
    .s_arvalid(p_arvalid[2]), .s_arready(p_arready[2]), .s_araddr(p_araddr[2]),
    .s_rvalid(p_rvalid[2]),   .s_rready(p_rready[2]),   .s_rdata(p_rdata[2]),   .s_rresp(p_rresp[2]),
    .s_awvalid(p_awvalid[2]), .s_awready(p_awready[2]), .s_awaddr(p_awaddr[2]),
    .s_wvalid(p_wvalid[2]),   .s_wready(p_wready[2]),   .s_wdata(p_wdata[2]),   .s_wstrb(p_wstrb[2]),
    .s_bvalid(p_bvalid[2]),   .s_bready(p_bready[2]),   .s_bresp(p_bresp[2])
  );

  soc_sysctrl u_sysctrl (
    .clk(clk_core), .rst_n(sys_rst_n), .boot_mode, .sw_rst_req, .core_ctl_out(sysctrl_core_ctl),
    .s_arvalid(p_arvalid[3]), .s_arready(p_arready[3]), .s_araddr(p_araddr[3]),
    .s_rvalid(p_rvalid[3]),   .s_rready(p_rready[3]),   .s_rdata(p_rdata[3]),   .s_rresp(p_rresp[3]),
    .s_awvalid(p_awvalid[3]), .s_awready(p_awready[3]), .s_awaddr(p_awaddr[3]),
    .s_wvalid(p_wvalid[3]),   .s_wready(p_wready[3]),   .s_wdata(p_wdata[3]),   .s_wstrb(p_wstrb[3]),
    .s_bvalid(p_bvalid[3]),   .s_bready(p_bready[3]),   .s_bresp(p_bresp[3])
  );

endmodule

`default_nettype wire
