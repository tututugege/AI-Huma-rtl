// Ref: rv_simu_mmu_v2.cpp  SimCpu::cycle + bridge_*_axi_* (MemSubsystem + AXI interconnect + LLC); MemSubsystem.cpp
`default_nettype none

// Memory subsystem top: the whole 16x-clocked memory domain behind the core's memory-side ports.
//   mem_route (LSU/ICache-probe/PTW -> DCache routing) -> dcache -> axi_subsys (interconnect + LLC) -> DDR slave port,
//   ptw_walk (page-table walker for the two TLBs), peripheral_axi (uncached / MMIO accesses) and the CPU-side view
//   registers of the non-DCache AXI masters (axi_cpu_port_adapter).
// `clk` is the fast tick clock (16 ticks per CPU cycle).  `phase0` is tick 0 of a CPU cycle; the CPU-domain
// registers of
// this block update only then, and the core (which has no enable) is clocked by a separate once-per-cycle clock
// that the
// testbench pulses together with the fast clock edge ending tick 0.
// Port names are the core_top names with the direction flipped, so soc_top can connect the two with `.*`.
module mem_top import ttg_cfg_pkg::*; import memcpu_pkg::*; import tlb_mmu_pkg::*;
#(
  parameter bit PF_EN = 1'b1
) (
  input  logic clk,
  input  logic rst_n,
  output logic phase0,
  // ---- core -> memory: ICache AXI read master / DCache probe / TLB walk clients / LSU ports / peripheral ----
  input  logic mem_req_valid,
  input  logic [31:0] mem_req_addr,
  input  logic [7:0] mem_req_total_size,
  input  logic mem_req_bypass,
  input  logic [3:0] mem_req_id,
  input  logic mem_resp_ready,
  input  logic dc_req_valid,
  input  logic [31:0] dc_req_addr,
  input  logic itlb_walk_req_valid,
  input  logic [VPN_W-1:0] itlb_walk_req_vpn,
  input  logic [21:0] itlb_walk_req_root_ppn,
  input  logic itlb_walk_resp_consumed,
  input  logic itlb_walk_flush,
  input  logic dtlb_walk_flush,
  input  logic [21:0] dtlb_walk_req_root_ppn,
  input  logic dtlb_walk_req_valid,
  input  logic [19:0] dtlb_walk_req_vpn,
  input  logic dtlb_walk_resp_consumed,
  input  logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT],
  input  logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT],
  input  logic lsu2dcache_load_ports_replay [LSU_LDU_COUNT],
  input  logic lsu2dcache_load_ports_valid [LSU_LDU_COUNT],
  input  logic [31:0] lsu2dcache_store_ports_addr [LSU_STA_COUNT],
  input  logic [31:0] lsu2dcache_store_ports_data [LSU_STA_COUNT],
  input  logic [5:0] lsu2dcache_store_ports_req_id [LSU_STA_COUNT],
  input  logic [4:0] lsu2dcache_store_ports_strb [LSU_STA_COUNT],
  input  logic lsu2dcache_store_ports_valid [LSU_STA_COUNT],
  input  logic peripheral_req_is_mmio,
  input  logic [31:0] peripheral_req_mmio_addr,
  input  logic [2:0] peripheral_req_mmio_fun3,
  input  logic [31:0] peripheral_req_mmio_wdata,
  input  logic peripheral_req_wen,
  // ---- memory -> core ----
  output logic mem_req_ready,
  output logic mem_req_accepted,
  output logic [3:0] mem_req_accepted_id,
  output logic mem_resp_valid,
  output logic [3:0] mem_resp_id,
  output logic [31:0] mem_resp_data [ICACHE_WORD_NUM],
  output logic dc_resp_valid,
  output logic dc_resp_retry,
  output logic dc_resp_miss,
  output logic [31:0] dc_resp_data,
  output logic itlb_walk_req_ready,
  output logic itlb_walk_resp_valid,
  output logic itlb_walk_resp_fault,
  output logic [VPN_W-1:0] itlb_walk_resp_vpn,
  output logic [PPN_W-1:0] itlb_walk_resp_leaf_ppn,
  output logic [PERM_W-1:0] itlb_walk_resp_leaf_perm,
  output logic itlb_walk_resp_leaf_level,
  output logic dtlb_walk_req_ready,
  output logic dtlb_walk_resp_valid,
  output logic dtlb_walk_resp_fault,
  output logic [VPN_W-1:0] dtlb_walk_resp_vpn,
  output logic [PPN_W-1:0] dtlb_walk_resp_leaf_ppn,
  output logic [PERM_W-1:0] dtlb_walk_resp_leaf_perm,
  output logic dtlb_walk_resp_leaf_level,
  output logic [31:0] dcache2lsu_load_resps_data [LSU_LDU_COUNT],
  output logic [1:0] dcache2lsu_load_resps_replay [LSU_LDU_COUNT],
  output logic [31:0] dcache2lsu_load_resps_req_id [LSU_LDU_COUNT],
  output logic dcache2lsu_load_resps_valid [LSU_LDU_COUNT],
  output logic dcache2lsu_load_retry_busy [LSU_LDU_COUNT], dcache2lsu_store_retry_busy [LSU_STA_COUNT],
  output logic dcache2lsu_mshr_fill,
  output logic [25:0] dcache2lsu_mshr_fill_line,
  output logic [1:0] dcache2lsu_store_resps_replay [LSU_STA_COUNT],
  output logic [31:0] dcache2lsu_store_resps_req_id [LSU_STA_COUNT],
  output logic dcache2lsu_store_resps_valid [LSU_STA_COUNT],
  output logic peripheral_resp_is_mmio,
  output logic [31:0] peripheral_resp_mmio_rdata,
  output logic peripheral_resp_ready,
  // ---- peripheral environment (testbench side: PeripheralModel / uncached RAM) ----
  input  logic [1:0] env_region,
  input  logic [31:0] env_rdata,
  output logic env_rd_en,
  output logic [31:0] env_rd_addr,
  output logic [2:0] env_rd_func3,
  output logic env_wr_en,
  output logic [31:0] env_wr_addr,
  output logic [31:0] env_wr_data,
  output logic [2:0] env_wr_func3,
  // ---- DDR slave port (testbench side: SimDDR) ----
  input  logic d_arready,
  input  logic d_rvalid,
  input  logic [5:0] d_rid,
  input  logic [255:0] d_rdata,
  input  logic d_awready,
  input  logic d_wready,
  input  logic d_bvalid,
  input  logic [5:0] d_bid,
  input  logic [1:0] d_bresp,
  output logic d_rready,
  output logic d_bready,
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

  localparam int NLD_ = LSU_LDU_COUNT;
  localparam int NST_ = LSU_STA_COUNT;

  // ---- tick phase: 0 = the CPU tick, TICKS-1 = the last one of the cycle ----
  // TICKS = AXI_SUBSYSTEM_FREQ_DIV (trace-model config.h): 1 = the memory domain runs at the CPU clock (phase0 and
  // phase_last are both always true), 16 = the original divided arrangement.
  localparam int TICKS = AXI_SUBSYSTEM_FREQ_DIV;
  logic [3:0] phase_q;
  always_ff @(posedge clk) begin
    if (!rst_n)                       phase_q <= 4'd0;
    else if (phase_q == 4'(TICKS - 1)) phase_q <= 4'd0;
    else                              phase_q <= phase_q + 4'd1;
  end
  // TICKS == 1: both are constant, so the 16-tick folding logic of the adapters and the DCache response latches
  // is removed at elaboration (phase_q is kept only as a probe point of the test bench)
  logic phase_last;
  if (TICKS == 1) begin : g_ph_const
    assign phase0     = 1'b1;
    assign phase_last = 1'b1;
  end else begin : g_ph_cnt
    assign phase0     = (phase_q == 4'd0);
    assign phase_last = (phase_q == 4'(TICKS - 1));
  end

  // ======================= mem_route =======================
  logic        rt_icache_resp_valid, rt_icache_resp_retry, rt_icache_resp_miss;
  logic [31:0] rt_icache_resp_data;
  logic        rt_ptw_event_valid, rt_ptw_wakeup_walk, rt_ptw_grant_valid;
  logic [31:0] rt_ptw_event_data;
  logic [PT_ID_W-1:0] rt_ptw_event_req_id, rt_ptw_grant_req_id;
  logic        rt_dc_ld_valid [NLD_];
  logic [31:0] rt_dc_ld_addr [NLD_], rt_dc_ld_id [NLD_];
  logic        rt_dc_ld_replay [NLD_];
  logic        rt_dc_st_valid [NST_];
  logic [31:0] rt_dc_st_addr [NST_], rt_dc_st_data [NST_];
  logic [ST_STRB_W-1:0] rt_dc_st_strb [NST_];
  logic [ST_ID_W-1:0]   rt_dc_st_id [NST_];
  logic        rt_dc_icache_probe;

  // dcache -> route
  logic        dc_ld_resp_valid [NLD_], dc_ld_resp_retry [NLD_];
  logic [31:0] dc_ld_resp_data [NLD_], dc_ld_resp_id [NLD_];
  logic [1:0]  dc_ld_resp_replay [NLD_];
  logic        dc_st_resp_valid [NST_];
  logic [1:0]  dc_st_resp_replay [NST_];
  logic [31:0] dc_st_resp_id [NST_];
  logic        dc_mshr_fill;
  logic [31:0] dc_mshr_fill_addr;

  // ptw_walk -> route
  logic        pw_issue_walk_read;
  logic [31:0] pw_walk_read_addr;

  mem_route u_route (
    .clk, .rst_n, .cpu_en(phase0),
    .dcache_resp_load_valid(dc_ld_resp_valid), .dcache_resp_load_req_id(dc_ld_resp_id),
    .dcache_resp_load_data(dc_ld_resp_data), .dcache_resp_load_replay(dc_ld_resp_replay),
    .dcache_resp_load3_retry(dc_ld_resp_retry[NLD_-1]),
    .dcache_resp_store_valid(dc_st_resp_valid), .dcache_resp_store_req_id(dc_st_resp_id),
    .dcache_resp_store_replay(dc_st_resp_replay),
    .dcache_resp_mshr_fill(dc_mshr_fill), .dcache_resp_mshr_fill_line(dc_mshr_fill_addr[31:6]),
    .lsu_req_load_valid(lsu2dcache_load_ports_valid), .lsu_req_load_addr(lsu2dcache_load_ports_addr),
    .lsu_req_load_req_id(lsu2dcache_load_ports_req_id), .lsu_req_load_replay(lsu2dcache_load_ports_replay),
    .lsu_req_store_valid(lsu2dcache_store_ports_valid), .lsu_req_store_addr(lsu2dcache_store_ports_addr),
    .lsu_req_store_data(lsu2dcache_store_ports_data), .lsu_req_store_strb(lsu2dcache_store_ports_strb),
    .lsu_req_store_req_id(lsu2dcache_store_ports_req_id),
    .icache_req_valid(dc_req_valid), .icache_req_addr(dc_req_addr),
    .ptw_walk_req_valid(pw_issue_walk_read), .ptw_walk_req_addr(pw_walk_read_addr),
    .lsu_resp_load_valid(dcache2lsu_load_resps_valid), .lsu_resp_load_req_id(dcache2lsu_load_resps_req_id),
    .lsu_resp_load_data(dcache2lsu_load_resps_data), .lsu_resp_load_replay(dcache2lsu_load_resps_replay),
    .lsu_resp_store_valid(dcache2lsu_store_resps_valid), .lsu_resp_store_req_id(dcache2lsu_store_resps_req_id),
    .lsu_resp_store_replay(dcache2lsu_store_resps_replay),
    .lsu_resp_mshr_fill(dcache2lsu_mshr_fill), .lsu_resp_mshr_fill_line(dcache2lsu_mshr_fill_line),
    .icache_resp_valid(rt_icache_resp_valid), .icache_resp_retry(rt_icache_resp_retry),
    .icache_resp_miss(rt_icache_resp_miss), .icache_resp_data(rt_icache_resp_data),
    .ptw_event_valid(rt_ptw_event_valid), .ptw_event_data(rt_ptw_event_data), .ptw_event_req_id(rt_ptw_event_req_id),
    .ptw_wakeup_walk(rt_ptw_wakeup_walk),
    .dcache_req_load_valid(rt_dc_ld_valid), .dcache_req_load_addr(rt_dc_ld_addr), .dcache_req_load_req_id(rt_dc_ld_id),
    .dcache_req_load_replay(rt_dc_ld_replay),
    .dcache_req_store_valid(rt_dc_st_valid), .dcache_req_store_addr(rt_dc_st_addr),
    .dcache_req_store_data(rt_dc_st_data), .dcache_req_store_strb(rt_dc_st_strb),
    .dcache_req_store_req_id(rt_dc_st_id),
    .dcache_req_icache_probe(rt_dc_icache_probe),
    .ptw_grant_valid(rt_ptw_grant_valid), .ptw_grant_req_id(rt_ptw_grant_req_id)
  );

  // The ICache runs (front_comb_before_back) before MemSubsystem::comb_outputs in a CPU cycle, so it reads the probe
  // response the
  // route block produced in the PREVIOUS cycle: one register stage on the route's icache response.
  logic        dc_resp_valid_q, dc_resp_retry_q, dc_resp_miss_q;
  logic [31:0] dc_resp_data_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dc_resp_valid_q <= 1'b0; dc_resp_retry_q <= 1'b0; dc_resp_miss_q <= 1'b0; dc_resp_data_q <= 32'd0;
    end else if (phase0) begin
      dc_resp_valid_q <= rt_icache_resp_valid; dc_resp_retry_q <= rt_icache_resp_retry;
      dc_resp_miss_q <= rt_icache_resp_miss;   dc_resp_data_q <= rt_icache_resp_data;
    end
  end
  assign dc_resp_valid = dc_resp_valid_q;
  assign dc_resp_retry = dc_resp_retry_q;
  assign dc_resp_miss  = dc_resp_miss_q;
  assign dc_resp_data  = dc_resp_data_q;

  // ======================= ptw_walk =======================
  // client 0 = DTLB, 1 = ITLB
  logic [PT_NCLIENT-1:0] pw_c_req_valid;
  logic [PT_VPN_W-1:0]  pw_c_req_vpn [PT_NCLIENT];
  logic [PT_PPN_IN_W-1:0] pw_c_req_root [PT_NCLIENT];
  logic                 pw_c_consumed [PT_NCLIENT], pw_c_flush [PT_NCLIENT];
  logic                 pw_c_req_ready [PT_NCLIENT], pw_c_resp_valid [PT_NCLIENT], pw_c_resp_fault [PT_NCLIENT];
  logic [PT_VPN_W-1:0]  pw_c_resp_vpn [PT_NCLIENT];
  logic [PT_PPN_W-1:0]  pw_c_resp_ppn [PT_NCLIENT];
  logic [PT_PERM_W-1:0] pw_c_resp_perm [PT_NCLIENT];
  logic [PT_NCLIENT-1:0] pw_c_resp_level;

  assign pw_c_req_valid[0] = dtlb_walk_req_valid;
  assign pw_c_req_vpn[0]   = dtlb_walk_req_vpn;
  assign pw_c_req_root[0]  = dtlb_walk_req_root_ppn;
  assign pw_c_consumed[0]  = dtlb_walk_resp_consumed;
  assign pw_c_flush[0]     = dtlb_walk_flush;
  assign pw_c_req_valid[1] = itlb_walk_req_valid;
  assign pw_c_req_vpn[1]   = itlb_walk_req_vpn;
  assign pw_c_req_root[1]  = itlb_walk_req_root_ppn;
  assign pw_c_consumed[1]  = itlb_walk_resp_consumed;
  assign pw_c_flush[1]     = itlb_walk_flush;

  ptw_walk u_ptw (
    .clk, .rst_n, .cpu_en(phase0),
    .client_req_valid(pw_c_req_valid), .client_req_vpn(pw_c_req_vpn), .client_req_root_ppn(pw_c_req_root),
    .client_resp_consumed(pw_c_consumed), .client_flush(pw_c_flush),
    .grant_valid(rt_ptw_grant_valid), .grant_req_id(rt_ptw_grant_req_id),
    .event_valid(rt_ptw_event_valid), .event_data(rt_ptw_event_data), .event_req_id(rt_ptw_event_req_id),
    .wakeup_walk(rt_ptw_wakeup_walk),
    .client_req_ready(pw_c_req_ready), .client_resp_valid(pw_c_resp_valid), .client_resp_fault(pw_c_resp_fault),
    .client_resp_vpn(pw_c_resp_vpn), .client_resp_leaf_ppn(pw_c_resp_ppn), .client_resp_leaf_perm(pw_c_resp_perm),
    .client_resp_leaf_level(pw_c_resp_level),
    .issue_walk_read(pw_issue_walk_read), .walk_read_addr(pw_walk_read_addr)
  );

  assign dtlb_walk_req_ready = pw_c_req_ready[0];
  assign dtlb_walk_resp_valid = pw_c_resp_valid[0];
  assign dtlb_walk_resp_fault = pw_c_resp_fault[0];
  assign dtlb_walk_resp_vpn = pw_c_resp_vpn[0];
  assign dtlb_walk_resp_leaf_ppn = pw_c_resp_ppn[0];
  assign dtlb_walk_resp_leaf_perm = pw_c_resp_perm[0];
  assign dtlb_walk_resp_leaf_level = pw_c_resp_level[0];
  assign itlb_walk_req_ready = pw_c_req_ready[1];
  assign itlb_walk_resp_valid = pw_c_resp_valid[1];
  assign itlb_walk_resp_fault = pw_c_resp_fault[1];
  assign itlb_walk_resp_vpn = pw_c_resp_vpn[1];
  assign itlb_walk_resp_leaf_ppn = pw_c_resp_ppn[1];
  assign itlb_walk_resp_leaf_perm = pw_c_resp_perm[1];
  assign itlb_walk_resp_leaf_level = pw_c_resp_level[1];

  // ======================= dcache =======================
  logic        mshr_req_valid, mshr_resp_ready, wb_req_valid;
  logic [31:0] mshr_req_addr, wb_req_addr;
  logic [dcache_pkg::MSHR_IDW-1:0] mshr_req_id;
  logic [31:0] wb_req_data [DCACHE_WORD_NUM];
  logic [31:0] mshr_resp_data [DCACHE_WORD_NUM];



  // LSU requests reach the DCache domain in tick 0 only; ticks 1..15 present an empty request (dcache_fast_comb(false))
  logic dc_ld_valid_in [NLD_], dc_st_valid_in [NST_];
  for (genvar l = 0; l < NLD_; l++) begin : g_ldgate
    assign dc_ld_valid_in[l] = rt_dc_ld_valid[l] & phase0;
  end
  for (genvar s = 0; s < NST_; s++) begin : g_stgate
    assign dc_st_valid_in[s] = rt_dc_st_valid[s] & phase0;
  end
  logic [2:0] dc_icache_req;
  assign dc_icache_req = (phase0 && rt_dc_icache_probe) ? 3'(NLD_ - 1) : 3'(NLD_);

  logic [3:0] rt_dc_st_strb4 [NST_];
  for (genvar s = 0; s < NST_; s++) begin : g_strb
    assign rt_dc_st_strb4[s] = rt_dc_st_strb[s][3:0];
  end
  logic [31:0] rt_dc_st_id32 [NST_];
  for (genvar s = 0; s < NST_; s++) begin : g_stid
    assign rt_dc_st_id32[s] = 32'(rt_dc_st_id[s]);
  end

  // AXI-side handshake wires (declared before their first use by u_dcache)
  logic        ax_mshr_acc, ax_mshr_rv, ax_wb_acc, ax_wb_rv;
  logic [3:0]  ax_mshr_acc_id, ax_mshr_rid;
  logic        ax_pa_rd_acc, ax_pa_rd_rv, ax_pa_wr_acc, ax_pa_wr_rv;
  logic [31:0] ax_pa_rd_data;

  dcache #(.PF_EN(PF_EN)) u_dcache (
    .clk, .rst_n, .cpu_phase0(phase0),
    .ld_req_valid(dc_ld_valid_in), .ld_req_addr(rt_dc_ld_addr), .ld_req_id(rt_dc_ld_id),
    .ld_req_replay(rt_dc_ld_replay),
    .st_req_valid(dc_st_valid_in), .st_req_addr(rt_dc_st_addr), .st_req_data(rt_dc_st_data),
    .st_req_strb(rt_dc_st_strb4), .st_req_id(rt_dc_st_id32),
    .icache_req(dc_icache_req),
    .mshr_req_accepted(ax_mshr_acc), .mshr_req_accepted_id({4'b0, ax_mshr_acc_id}),
    .mshr_resp_valid(ax_mshr_rv), .mshr_resp_id({4'b0, ax_mshr_rid}),
    .mshr_resp_data(mshr_resp_data),
    .wb_req_accepted(ax_wb_acc), .wb_resp_valid(ax_wb_rv),
    .ld_resp_valid(dc_ld_resp_valid), .ld_resp_data(dc_ld_resp_data), .ld_resp_id(dc_ld_resp_id),
    .ld_resp_retry(dc_ld_resp_retry), .ld_resp_replay(dc_ld_resp_replay),
    .ld_retry_busy(dcache2lsu_load_retry_busy), .st_retry_busy(dcache2lsu_store_retry_busy),
    .st_resp_valid(dc_st_resp_valid), .st_resp_replay(dc_st_resp_replay), .st_resp_id(dc_st_resp_id),
    .mshr_fill(dc_mshr_fill), .mshr_fill_addr(dc_mshr_fill_addr),
    .mshr_req_valid(mshr_req_valid), .mshr_req_addr(mshr_req_addr), .mshr_req_id(mshr_req_id),
    .mshr_resp_ready(mshr_resp_ready),
    .wb_req_valid(wb_req_valid), .wb_req_addr(wb_req_addr), .wb_req_data(wb_req_data)
  );

  // ======================= peripheral_axi + hold register =======================
  logic        pa_resp_ready, pa_resp_is_mmio;
  logic [31:0] pa_resp_rdata;
  logic        pa_rd_valid, pa_rd_resp_ready, pa_wr_valid, pa_wr_resp_ready;
  logic [31:0] pa_rd_addr, pa_wr_addr, pa_wr_wdata;
  logic [PA_SIZE_W-1:0] pa_rd_size, pa_wr_size;
  logic [3:0]  pa_wr_wstrb;

  // CPU-side AXI views of the non-DCache masters (0 = ICache read, 1 = peripheral read, 2 = peripheral write)

  peripheral_axi u_periph (
    .clk, .rst_n, .cpu_en(phase0),
    .req_is_mmio(peripheral_req_is_mmio), .req_wen(peripheral_req_wen), .req_addr(peripheral_req_mmio_addr),
    .req_wdata(peripheral_req_mmio_wdata), .req_func3(peripheral_req_mmio_fun3),
    .env_region(env_region), .env_rdata(env_rdata),
    .axi_rd_req_accepted(ax_pa_rd_acc), .axi_rd_resp_valid(ax_pa_rd_rv), .axi_rd_resp_data(ax_pa_rd_data),
    .axi_wr_req_accepted(ax_pa_wr_acc), .axi_wr_resp_valid(ax_pa_wr_rv),
    .resp_ready(pa_resp_ready), .resp_is_mmio(pa_resp_is_mmio), .resp_rdata(pa_resp_rdata),
    .axi_rd_req_valid(pa_rd_valid), .axi_rd_req_addr(pa_rd_addr), .axi_rd_req_size(pa_rd_size),
    .axi_rd_resp_ready(pa_rd_resp_ready),
    .axi_wr_req_valid(pa_wr_valid), .axi_wr_req_addr(pa_wr_addr), .axi_wr_req_size(pa_wr_size),
    .axi_wr_req_wstrb(pa_wr_wstrb), .axi_wr_req_wdata(pa_wr_wdata), .axi_wr_resp_ready(pa_wr_resp_ready),
    .env_rd_en, .env_rd_addr, .env_rd_func3, .env_wr_en, .env_wr_addr, .env_wr_data, .env_wr_func3
  );

  // SimCpu::peripheral_resp_hold: this cycle's peripheral response is what the core sees in the next cycle
  logic        hold_ready_q, hold_is_mmio_q;
  logic [31:0] hold_rdata_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hold_ready_q <= 1'b0; hold_is_mmio_q <= 1'b0; hold_rdata_q <= 32'd0;
    end else if (phase0) begin
      hold_ready_q <= pa_resp_ready; hold_is_mmio_q <= pa_resp_is_mmio; hold_rdata_q <= pa_resp_rdata;
    end
  end
  assign peripheral_resp_ready   = hold_ready_q;
  assign peripheral_resp_is_mmio = hold_is_mmio_q;
  assign peripheral_resp_mmio_rdata = hold_rdata_q;

  // ======================= AXI side =======================
  mem_axi u_axi (
    .clk, .rst_n, .phase0, .phase_last,
    .mem_req_valid, .mem_req_addr, .mem_req_total_size, .mem_req_bypass, .mem_req_id, .mem_resp_ready,
    .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id, .mem_resp_data,
    .mshr_req_valid, .mshr_req_addr, .mshr_req_id(4'(mshr_req_id)), .mshr_resp_ready,
    .wb_req_valid, .wb_req_addr, .wb_req_data,
    .mshr_req_accepted(ax_mshr_acc), .mshr_req_accepted_id(ax_mshr_acc_id), .mshr_resp_valid(ax_mshr_rv),
    .mshr_resp_id(ax_mshr_rid), .mshr_resp_data,
    .wb_req_accepted(ax_wb_acc), .wb_resp_valid(ax_wb_rv),
    .pa_rd_valid, .pa_rd_addr, .pa_rd_size, .pa_rd_resp_ready, .pa_wr_valid, .pa_wr_addr, .pa_wr_size,
    .pa_wr_wstrb, .pa_wr_wdata, .pa_wr_resp_ready,
    .pa_rd_accepted(ax_pa_rd_acc), .pa_rd_resp_valid(ax_pa_rd_rv), .pa_rd_resp_data(ax_pa_rd_data),
    .pa_wr_accepted(ax_pa_wr_acc), .pa_wr_resp_valid(ax_pa_wr_rv),
    .d_arready, .d_rvalid, .d_rid, .d_rdata, .d_awready, .d_wready, .d_bvalid, .d_bid, .d_bresp,
    .d_rready, .d_bready, .d_arvalid, .d_arid, .d_araddr, .d_arlen, .d_awvalid, .d_awid, .d_awaddr, .d_awlen,
    .d_wvalid, .d_wdata, .d_wstrb, .d_wlast
  );

  wire unused_fill = &{1'b0, dc_mshr_fill_addr[5:0]};
endmodule
`default_nettype wire
