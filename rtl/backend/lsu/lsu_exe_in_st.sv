// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_exe2lsu: handle_store_data, handle_store_addr)
`default_nettype none

module lsu_exe_in_st
  import lsu_pkg::*;
(
  input  logic [NSDU-1:0]  sdu_valid,
  input  logic [31:0]      sdu_result    [NSDU],
  input  logic [6:0]       sdu_rob_idx   [NSDU],
  input  logic             sdu_rob_flag  [NSDU],
  input  logic [SQW-1:0]   sdu_stq_idx   [NSDU],
  input  logic [NST-1:0]   sta_valid,
  input  logic [31:0]      sta_result    [NST],
  input  logic [6:0]       sta_dest_preg [NST],
  input  logic [2:0]       sta_func3     [NST],
  input  logic [NST-1:0]   sta_is_atomic,
  input  logic [4:0]       sta_amo_op    [NST],
  input  logic [6:0]       sta_rob_idx   [NST],
  input  logic             sta_rob_flag  [NST],
  input  logic [SQW-1:0]   sta_stq_idx   [NST],
  input  logic [6:0]       st_rob_idx    [SQ],
  input  logic [SQ-1:0]    st_rob_flag,
  input  lsu_ring_t        mdone_i,
  input  lsu_ring_t        wmst_i,
  input  st_state_t        st_st_i       [SQ],
  input  logic [SQ-1:0]    st_data_valid_i,
  input  logic [31:0]      st_data_i     [SQ],
  input  logic [SQ-1:0]    st_paddr_valid_i,
  input  logic [31:0]      st_vaddr_i    [SQ],
  input  logic [2:0]       st_func3_i    [SQ],
  input  logic [6:0]       st_dest_i     [SQ],
  input  logic [SQ-1:0]    st_is_lrsc_i,
  output lsu_ring_t        mdone_o,
  output lsu_ring_t        wmst_o,
  output st_state_t        st_st_o       [SQ],
  output logic [SQ-1:0]    st_data_valid_o,
  output logic [31:0]      st_data_o     [SQ],
  output logic [SQ-1:0]    st_paddr_valid_o,
  output logic [31:0]      st_vaddr_o    [SQ],
  output logic [2:0]       st_func3_o    [SQ],
  output logic [6:0]       st_dest_o     [SQ],
  output logic [SQ-1:0]    st_is_lrsc_o
);

  // the request only takes effect when it matches the entry's ROB tag (stale/mismatching requests are dropped);
  // the entry's own state is not looked at.
  logic [NSDU-1:0] sdu_hit, sdu_ready;
  logic [NST-1:0]  sta_hit;
  for (genvar p = 0; p < NSDU; p++) begin : g_sdu
    assign sdu_hit[p]   = sdu_valid[p] && st_rob_idx[sdu_stq_idx[p]] == sdu_rob_idx[p] &&
                          st_rob_flag[sdu_stq_idx[p]] == sdu_rob_flag[p];
    assign sdu_ready[p] = sdu_hit[p] && st_paddr_valid_i[sdu_stq_idx[p]] && st_st_i[sdu_stq_idx[p]] == ST_WAIT_DATA;
  end
  for (genvar p = 0; p < NST; p++) begin : g_sta
    assign sta_hit[p] = sta_valid[p] && st_rob_idx[sta_stq_idx[p]] == sta_rob_idx[p] &&
                        st_rob_flag[sta_stq_idx[p]] == sta_rob_flag[p];
  end

  for (genvar e = 0; e < SQ; e++) begin : g_entry
    logic [NSDU-1:0] d_sel, r_sel;
    logic [NST-1:0]  a_sel;
    for (genvar p = 0; p < NSDU; p++) begin : g_d
      assign d_sel[p] = sdu_hit[p] && sdu_stq_idx[p] == SQW'(e);
      assign r_sel[p] = sdu_ready[p] && sdu_stq_idx[p] == SQW'(e);
    end
    for (genvar p = 0; p < NST; p++) begin : g_a
      assign a_sel[p] = sta_hit[p] && sta_stq_idx[p] == SQW'(e);
    end
    always_comb begin
      st_data_valid_o[e]  = st_data_valid_i[e] || (|d_sel);
      st_data_o[e]        = st_data_i[e];
      for (int p = NSDU - 1; p >= 0; p--) if (d_sel[p]) st_data_o[e] = sdu_result[p];
      // STA (handled after STD) overrides the state/address fields
      st_st_o[e]          = (|r_sel) ? ST_READY : st_st_i[e];
      st_paddr_valid_o[e] = (|a_sel) ? 1'b0 : st_paddr_valid_i[e];
      st_vaddr_o[e]       = st_vaddr_i[e];
      st_func3_o[e]       = st_func3_i[e];
      st_dest_o[e]        = st_dest_i[e];
      st_is_lrsc_o[e]     = st_is_lrsc_i[e];
      if (|a_sel) st_st_o[e] = ST_WAIT_TLB;
      for (int p = NST - 1; p >= 0; p--) begin
        if (a_sel[p]) begin
          st_vaddr_o[e]   = sta_result[p];
          st_func3_o[e]   = sta_func3[p];
          st_dest_o[e]    = sta_dest_preg[p];
          st_is_lrsc_o[e] = sta_is_atomic[p] && sta_amo_op[p] == AMO_SC;
        end
      end
    end
  end

  // queue appends: STD completions -> mmu_done, STA -> wait_mmu_stq (port order)
  lsu_ring_app #(.NA(NSDU)) u_mdone (.ring_i(mdone_i), .app_en(sdu_ready), .app_idx(sdu_stq_idx), .ring_o(mdone_o));
  lsu_ring_app #(.NA(NST))  u_wmst  (.ring_i(wmst_i),  .app_en(sta_hit),   .app_idx(sta_stq_idx), .ring_o(wmst_o));

endmodule

`default_nettype wire
