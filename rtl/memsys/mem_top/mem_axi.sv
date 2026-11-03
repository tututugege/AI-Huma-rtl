// Ref: rv_simu_mmu_v2.cpp  bridge_axi_to_mem_subsystem / bridge_mem_subsystem_to_axi, axi_subsystem_* (AXI side of
// mem_top)
`default_nettype none

// The AXI side of the memory subsystem: master-port glue of the four masters (ICache read, DCache MSHR read,
// DCache write buffer,
// peripheral read/write), the interconnect + LLC (axi_subsys) and the CPU-side views of the non-DCache masters
// (adapter).
module mem_axi import ttg_cfg_pkg::*; import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic phase0,
  input  logic phase_last,
  // ICache read master (core side)
  input  logic mem_req_valid,
  input  logic [31:0] mem_req_addr,
  input  logic [7:0] mem_req_total_size,
  input  logic mem_req_bypass,
  input  logic [3:0] mem_req_id,
  input  logic mem_resp_ready,
  output logic mem_req_ready,
  output logic mem_req_accepted,
  output logic [3:0] mem_req_accepted_id,
  output logic mem_resp_valid,
  output logic [3:0] mem_resp_id,
  output logic [31:0] mem_resp_data [ICACHE_WORD_NUM],
  // DCache MSHR read master / write buffer
  input  logic mshr_req_valid,
  input  logic [31:0] mshr_req_addr,
  input  logic [3:0] mshr_req_id,
  input  logic mshr_resp_ready,
  input  logic wb_req_valid,
  input  logic [31:0] wb_req_addr,
  input  logic [31:0] wb_req_data [DCACHE_WORD_NUM],
  output logic mshr_req_accepted,
  output logic [3:0] mshr_req_accepted_id,
  output logic mshr_resp_valid,
  output logic [3:0] mshr_resp_id,
  output logic [31:0] mshr_resp_data [DCACHE_WORD_NUM],
  output logic wb_req_accepted,
  output logic wb_resp_valid,
  // peripheral read / write masters
  input  logic pa_rd_valid,
  input  logic [31:0] pa_rd_addr,
  input  logic [PA_SIZE_W-1:0] pa_rd_size,
  input  logic pa_rd_resp_ready,
  input  logic pa_wr_valid,
  input  logic [31:0] pa_wr_addr,
  input  logic [PA_SIZE_W-1:0] pa_wr_size,
  input  logic [3:0] pa_wr_wstrb,
  input  logic [31:0] pa_wr_wdata,
  input  logic pa_wr_resp_ready,
  output logic pa_rd_accepted,
  output logic pa_rd_resp_valid,
  output logic [31:0] pa_rd_resp_data,
  output logic pa_wr_accepted,
  output logic pa_wr_resp_valid,
  // DDR slave port
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
  logic [3:0]  ax_rd_accepted_id [4], ax_rd_resp_id [4];
  logic        ax_rd_accepted [4], ax_rd_resp_valid [4];
  logic [511:0] ax_rd_resp_data [4];
  logic        ax_wr_accepted [2], ax_wr_resp_valid [2];
  logic        ax_rd_acc_new [4], ax_wr_acc_new [2];
  logic [3:0]  ax_rd_acc_new_id [4];
  logic [3:0]  ax_wr_resp_id [2];
  logic [1:0]  ax_wr_resp_resp [2];
  logic        ax_rd0_ready, ax_rd3_ready, ax_wr1_ready;
  logic        ad_ready [AX_NCH], ad_accepted [AX_NCH], ad_resp_valid [AX_NCH], ad_resp_ready [AX_NCH];
  logic [AX_ID_W-1:0] ad_accepted_id [AX_NCH], ad_resp_id [AX_NCH];
  logic        raw_ready [AX_NCH], raw_accepted [AX_NCH], raw_resp_valid [AX_NCH], raw_resp_ready [AX_NCH];
  logic [AX_ID_W-1:0] raw_accepted_id [AX_NCH], raw_resp_id [AX_NCH];
  for (genvar w = 0; w < DCACHE_WORD_NUM; w++) begin : g_mshr_data
    assign mshr_resp_data[w] = ax_rd_resp_data[1][32*w +: 32];
  end

  // ======================= AXI interconnect + LLC =======================
  // master inputs: the DCache masters run every tick; the CPU masters (ICache, peripheral) act in tick 0 only
  // (mask_axi_cpu_boundary_for_internal_tick).
  logic        m_rd_valid [4], m_rd_bypass [4], m_rd_resp_ready [4];
  logic [31:0] m_rd_addr [4];
  logic [7:0]  m_rd_size [4];
  logic [3:0]  m_rd_id [4];
  logic        m_wr_valid [2], m_wr_bypass [2], m_wr_resp_ready [2];
  logic [31:0] m_wr_addr [2];
  logic [511:0] m_wr_data [2];
  logic [63:0] m_wr_strb [2];
  logic [7:0]  m_wr_size [2];
  logic [3:0]  m_wr_id [2];

  // read master 0: ICache
  assign m_rd_valid[0]      = phase0 & mem_req_valid;
  assign m_rd_addr[0]       = phase0 ? mem_req_addr : 32'd0;
  assign m_rd_size[0]       = phase0 ? mem_req_total_size : 8'd0;
  assign m_rd_id[0]         = phase0 ? mem_req_id : 4'd0;
  assign m_rd_bypass[0]     = phase0 & mem_req_bypass;
  assign m_rd_resp_ready[0] = phase0 & mem_resp_ready;
  // read master 1: DCache MSHR (line fills, 64 B)
  assign m_rd_valid[1]      = mshr_req_valid;
  assign m_rd_addr[1]       = mshr_req_addr;
  assign m_rd_size[1]       = 8'd63;
  assign m_rd_id[1]         = mshr_req_id;
  assign m_rd_bypass[1]     = 1'b0;
  assign m_rd_resp_ready[1] = mshr_resp_ready;
  // read master 2: unused (UNCORE_LSU_R)
  assign m_rd_valid[2]      = 1'b0;
  assign m_rd_addr[2]       = 32'd0;
  assign m_rd_size[2]       = 8'd0;
  assign m_rd_id[2]         = 4'd0;
  assign m_rd_bypass[2]     = 1'b0;
  assign m_rd_resp_ready[2] = 1'b0;
  // read master 3: peripheral
  assign m_rd_valid[3]      = phase0 & pa_rd_valid;
  assign m_rd_addr[3]       = phase0 ? pa_rd_addr : 32'd0;
  assign m_rd_size[3]       = phase0 ? 8'(pa_rd_size) : 8'd0;
  assign m_rd_id[3]         = 4'd0;
  assign m_rd_bypass[3]     = phase0;
  assign m_rd_resp_ready[3] = phase0 & pa_rd_resp_ready;
  // write master 0: DCache write buffer
  assign m_wr_valid[0]      = wb_req_valid;
  assign m_wr_addr[0]       = wb_req_addr;
  for (genvar w = 0; w < DCACHE_WORD_NUM; w++) begin : g_wbdata
    assign m_wr_data[0][32*w +: 32] = wb_req_data[w];
  end
  assign m_wr_strb[0]       = '1;
  assign m_wr_size[0]       = 8'd63;
  assign m_wr_id[0]         = 4'd0;
  assign m_wr_bypass[0]     = 1'b0;
  assign m_wr_resp_ready[0] = 1'b1;
  // write master 1: peripheral
  assign m_wr_valid[1]      = phase0 & pa_wr_valid;
  assign m_wr_addr[1]       = phase0 ? pa_wr_addr : 32'd0;
  assign m_wr_data[1]       = phase0 ? 512'(pa_wr_wdata) : 512'd0;
  assign m_wr_strb[1]       = phase0 ? 64'(pa_wr_wstrb) : 64'd0;
  assign m_wr_size[1]       = phase0 ? 8'(pa_wr_size) : 8'd0;
  assign m_wr_id[1]         = 4'd0;
  assign m_wr_bypass[1]     = phase0;
  assign m_wr_resp_ready[1] = phase0 & pa_wr_resp_ready;

  axi_subsys u_axi (
    .clk, .rst_n, .phase0,
    .m_rd_valid, .m_rd_addr, .m_rd_size, .m_rd_id, .m_rd_bypass, .m_rd_resp_ready,
    .m_wr_valid, .m_wr_addr, .m_wr_data, .m_wr_strb, .m_wr_size, .m_wr_id, .m_wr_bypass, .m_wr_resp_ready,
    .d_arready, .d_rvalid, .d_rid, .d_rdata, .d_awready, .d_wready, .d_bvalid, .d_bid, .d_bresp,
    .m_rd_resp_valid(ax_rd_resp_valid), .m_rd_resp_id(ax_rd_resp_id), .m_rd_resp_data(ax_rd_resp_data),
    .m_rd_accepted(ax_rd_accepted), .m_rd_accepted_id(ax_rd_accepted_id),
    .m_rd_acc_new(ax_rd_acc_new), .m_rd_acc_new_id(ax_rd_acc_new_id), .m_wr_acc_new(ax_wr_acc_new),
    .m_wr_accepted(ax_wr_accepted), .m_wr_resp_valid(ax_wr_resp_valid), .m_wr_resp_id(ax_wr_resp_id),
    .m_wr_resp_resp(ax_wr_resp_resp),
    .d_rready, .d_bready, .m_rd0_req_ready(ax_rd0_ready), .m_rd3_req_ready(ax_rd3_ready),
        .m_wr1_req_ready(ax_wr1_ready),
    .d_arvalid, .d_arid, .d_araddr, .d_arlen, .d_awvalid, .d_awid, .d_awaddr, .d_awlen,
    .d_wvalid, .d_wdata, .d_wstrb, .d_wlast
  );

  // ---- CPU views of the non-DCache masters ----
  assign raw_ready[0] = ax_rd0_ready;
  assign raw_ready[1] = ax_rd3_ready;
  assign raw_ready[2] = ax_wr1_ready;
  // the C++ adapter samples the accepted STATE after each tick's seq = the accepted-this-tick value of that tick
  assign raw_accepted[0] = ax_rd_acc_new[0];
  assign raw_accepted[1] = ax_rd_acc_new[3];
  assign raw_accepted[2] = ax_wr_acc_new[1];
  assign raw_accepted_id[0] = ax_rd_acc_new_id[0]; assign raw_accepted_id[1] = ax_rd_acc_new_id[3];
  assign raw_accepted_id[2] = '0;
  assign raw_resp_valid[0] = ax_rd_resp_valid[0];
  assign raw_resp_valid[1] = ax_rd_resp_valid[3];
  assign raw_resp_valid[2] = ax_wr_resp_valid[1];
  assign raw_resp_id[0] = ax_rd_resp_id[0];
  assign raw_resp_id[1] = ax_rd_resp_id[3];
  assign raw_resp_id[2] = ax_wr_resp_id[1];
  assign raw_resp_ready[0] = m_rd_resp_ready[0];
  assign raw_resp_ready[1] = m_rd_resp_ready[3];
  assign raw_resp_ready[2] = m_wr_resp_ready[1];

  axi_cpu_port_adapter u_adapt (
    .clk, .rst_n, .phase0, .phase_last,
    .raw_ready, .raw_accepted, .raw_accepted_id, .raw_resp_valid, .raw_resp_id, .raw_resp_ready,
    .cpu_ready(ad_ready), .cpu_accepted(ad_accepted), .cpu_accepted_id(ad_accepted_id),
    .cpu_resp_valid(ad_resp_valid), .cpu_resp_id(ad_resp_id), .cpu_resp_ready(ad_resp_ready)
  );

  assign mem_req_ready       = ad_ready[0];
  assign mem_req_accepted    = ad_accepted[0];
  assign mem_req_accepted_id = ad_accepted_id[0];
  assign mem_resp_valid      = ad_resp_valid[0];
  assign mem_resp_id         = ad_resp_id[0];
  for (genvar w = 0; w < ICACHE_WORD_NUM; w++) begin : g_icdata
    assign mem_resp_data[w] = ax_rd_resp_data[0][32*w +: 32];
  end

  wire unused = &{1'b0, ax_wr_resp_resp[0], ax_wr_resp_resp[1],
                  ad_resp_ready[0], ad_resp_ready[1], ad_resp_ready[2], ad_ready[1], ad_ready[2],
                  ad_accepted_id[1], ad_accepted_id[2], ad_resp_id[1], ad_resp_id[2], ax_rd_resp_valid[2],
                  m_rd_valid[2], ax_rd_accepted[2]};


  assign mshr_req_accepted    = ax_rd_accepted[1];
  assign mshr_req_accepted_id = ax_rd_accepted_id[1];
  assign mshr_resp_valid      = ax_rd_resp_valid[1];
  assign mshr_resp_id         = ax_rd_resp_id[1];
  assign wb_req_accepted      = ax_wr_accepted[0];
  assign wb_resp_valid        = ax_wr_resp_valid[0];
  assign pa_rd_accepted       = ad_accepted[1];
  assign pa_rd_resp_valid     = ad_resp_valid[1];
  assign pa_rd_resp_data      = ax_rd_resp_data[3][31:0];
  assign pa_wr_accepted       = ad_accepted[2];
  assign pa_wr_resp_valid     = ad_resp_valid[2];
endmodule
`default_nettype wire
