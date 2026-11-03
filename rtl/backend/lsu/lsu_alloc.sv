// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_dis2lsu: alloc_ldq_entry, alloc_stq_entry)
`default_nettype none

module lsu_alloc
  import lsu_pkg::*;
(
  input  logic [NDIS-1:0]  ldq_req,
  input  logic [LQW-1:0]   ldq_idx      [NDIS],
  input  logic [BRW-1:0]   ldq_br_mask  [NDIS],
  input  logic [6:0]       ldq_rob_idx  [NDIS],
  input  logic             ldq_rob_flag [NDIS],
  input  logic [NDIS-1:0]  stq_req,
  input  logic [BRW-1:0]   stq_br_mask  [NDIS],
  input  logic [6:0]       stq_rob_idx  [NDIS],
  input  logic             stq_rob_flag [NDIS],
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_count_i,
  // LDQ arrays
  input  ld_state_t        ld_st_i       [LQ],
  input  logic [6:0]       ld_rob_idx_i  [LQ],
  input  logic [LQ-1:0]    ld_rob_flag_i,
  input  logic [BRW-1:0]   ld_br_mask_i  [LQ],
  input  logic [LQ-1:0]    ld_pf_i,
  input  logic [1:0]       ld_replay_i   [LQ],
  output ld_state_t        ld_st_o       [LQ],
  output logic [6:0]       ld_rob_idx_o  [LQ],
  output logic [LQ-1:0]    ld_rob_flag_o,
  output logic [BRW-1:0]   ld_br_mask_o  [LQ],
  output logic [LQ-1:0]    ld_pf_o,
  output logic [1:0]       ld_replay_o   [LQ],
  // STQ arrays
  input  st_state_t        st_st_i        [SQ],
  input  logic [SQ-1:0]    st_data_valid_i,
  input  logic [SQ-1:0]    st_paddr_valid_i,
  input  logic [SQ-1:0]    st_pf_i,
  input  logic [SQ-1:0]    st_suppress_i,
  input  logic [SQ-1:0]    st_mmio_i,
  input  logic [SQ-1:0]    st_is_lrsc_i,
  input  logic [SQ-1:0]    st_sc_pass_i,
  input  logic [1:0]       st_replay_i    [SQ],
  input  logic [RWW-1:0]   st_wait_i      [SQ],
  input  logic [BRW-1:0]   st_br_mask_i   [SQ],
  input  logic [6:0]       st_rob_idx_i   [SQ],
  input  logic [SQ-1:0]    st_rob_flag_i,
  output st_state_t        st_st_o        [SQ],
  output logic [SQ-1:0]    st_data_valid_o,
  output logic [SQ-1:0]    st_paddr_valid_o,
  output logic [SQ-1:0]    st_pf_o,
  output logic [SQ-1:0]    st_suppress_o,
  output logic [SQ-1:0]    st_mmio_o,
  output logic [SQ-1:0]    st_is_lrsc_o,
  output logic [SQ-1:0]    st_sc_pass_o,
  output logic [1:0]       st_replay_o    [SQ],
  output logic [RWW-1:0]   st_wait_o      [SQ],
  output logic [BRW-1:0]   st_br_mask_o   [SQ],
  output logic [6:0]       st_rob_idx_o   [SQ],
  output logic [SQ-1:0]    st_rob_flag_o,
  output logic [RCW-1:0]   stq_count_o
);

  // ---- LDQ: Dispatch names the (Empty) entry ----
  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [NDIS-1:0] sel;
    for (genvar i = 0; i < NDIS; i++) begin : g_p
      assign sel[i] = ldq_req[i] && ldq_idx[i] == LQW'(e);
    end
    always_comb begin
      ld_st_o[e]       = (|sel) ? LD_ALLOCATED : ld_st_i[e];
      ld_pf_o[e]       = (|sel) ? 1'b0 : ld_pf_i[e];
      ld_replay_o[e]   = (|sel) ? REPLAY_HIT : ld_replay_i[e];   // entry = {}: replay_type is read by the MSHR wake-up
      ld_rob_idx_o[e]  = ld_rob_idx_i[e];
      ld_rob_flag_o[e] = ld_rob_flag_i[e];
      ld_br_mask_o[e]  = ld_br_mask_i[e];
      for (int i = NDIS - 1; i >= 0; i--) begin
        if (sel[i]) begin
          ld_rob_idx_o[e]  = ldq_rob_idx[i];
          ld_rob_flag_o[e] = ldq_rob_flag[i];
          ld_br_mask_o[e]  = ldq_br_mask[i];
        end
      end
    end
  end

  // ---- STQ: the k-th accepted request goes to slot head + count + k while count + k < STQ_SIZE ----
  logic [NDIS-1:0] acc;
  logic [RCW-1:0]  rank [NDIS];
  logic [RCW-1:0]  total_acc;
  lsu_rank #(.N(NDIS), .CW(RCW)) u_rank (.bits(stq_req), .rank(rank));
  for (genvar i = 0; i < NDIS; i++) begin : g_acc
    assign acc[i] = stq_req[i] && stq_count_i + rank[i] < RCW'(SQ);
  end
  ttg_popcount #(.N(NDIS), .CW(RCW)) u_total (.bits(acc), .count(total_acc));
  assign stq_count_o = stq_count_i + total_acc;

  for (genvar e = 0; e < SQ; e++) begin : g_st
    logic [NDIS-1:0] sel;
    for (genvar i = 0; i < NDIS; i++) begin : g_p
      assign sel[i] = acc[i] && stq_head + RIW'(stq_count_i) + RIW'(rank[i]) == RIW'(e);
    end
    always_comb begin
      st_st_o[e]           = (|sel) ? ST_ALLOCATED : st_st_i[e];
      st_data_valid_o[e]   = (|sel) ? 1'b0 : st_data_valid_i[e];
      st_paddr_valid_o[e]  = (|sel) ? 1'b0 : st_paddr_valid_i[e];
      st_pf_o[e]           = (|sel) ? 1'b0 : st_pf_i[e];
      st_suppress_o[e]     = (|sel) ? 1'b0 : st_suppress_i[e];
      st_mmio_o[e]         = (|sel) ? 1'b0 : st_mmio_i[e];
      st_is_lrsc_o[e]      = (|sel) ? 1'b0 : st_is_lrsc_i[e];
      st_sc_pass_o[e]      = (|sel) ? 1'b0 : st_sc_pass_i[e];
      st_replay_o[e]       = (|sel) ? REPLAY_HIT : st_replay_i[e];
      st_wait_o[e]         = (|sel) ? '0 : st_wait_i[e];
      st_br_mask_o[e]      = st_br_mask_i[e];
      st_rob_idx_o[e]      = st_rob_idx_i[e];
      st_rob_flag_o[e]     = st_rob_flag_i[e];
      for (int i = NDIS - 1; i >= 0; i--) begin
        if (sel[i]) begin
          st_br_mask_o[e]  = stq_br_mask[i];
          st_rob_idx_o[e]  = stq_rob_idx[i];
          st_rob_flag_o[e] = stq_rob_flag[i];
        end
      end
    end
  end

endmodule

`default_nettype wire
