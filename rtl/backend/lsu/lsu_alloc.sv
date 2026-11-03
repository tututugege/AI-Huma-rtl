// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_dis2lsu: alloc_ldq_entry, alloc_stq_entry)
`default_nettype none

// K: Dispatch allocates LDQ entries (it names the Empty entry) and STQ entries (the k-th accepted request goes to
// slot head + count + k while count + k < STQ_SIZE).
module lsu_alloc
  import lsu_pkg::*;
(
  input  logic [NDIS-1:0]  ldq_req,
  input  logic [LQW-1:0]   ldq_idx      [NDIS],
  input  logic [BRW-1:0]   ldq_br_mask  [NDIS],
  input  logic [ROBW-1:0]  ldq_rob_idx  [NDIS],
  input  logic             ldq_rob_flag [NDIS],
  input  logic [NDIS-1:0]  stq_req,
  input  logic [BRW-1:0]   stq_br_mask  [NDIS],
  input  logic [ROBW-1:0]  stq_rob_idx  [NDIS],
  input  logic             stq_rob_flag [NDIS],
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_count,
  output ldq_al_t          ld_ev        [LQ],
  output stq_al_t          st_ev        [SQ],
  output logic [RCW-1:0]   stq_count_al             // STQ count after the allocations
);

  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [NDIS-1:0] sel;
    for (genvar i = 0; i < NDIS; i++) begin : g_p
      assign sel[i] = ldq_req[i] && ldq_idx[i] == LQW'(e);
    end
    always_comb begin
      ld_ev[e]    = '0;
      ld_ev[e].go = |sel;
      for (int i = NDIS - 1; i >= 0; i--) begin
        if (sel[i]) begin
          ld_ev[e].rob_idx  = ldq_rob_idx[i];
          ld_ev[e].rob_flag = ldq_rob_flag[i];
          ld_ev[e].br_mask  = ldq_br_mask[i];
        end
      end
    end
  end

  logic [NDIS-1:0] acc;
  logic [RCW-1:0]  rank [NDIS];
  logic [RCW-1:0]  total_acc;
  lsu_rank #(.N(NDIS), .CW(RCW)) u_rank (.bits(stq_req), .rank(rank));
  for (genvar i = 0; i < NDIS; i++) begin : g_acc
    assign acc[i] = stq_req[i] && stq_count + rank[i] < RCW'(SQ);
  end
  ttg_popcount #(.N(NDIS), .CW(RCW)) u_total (.bits(acc), .count(total_acc));
  assign stq_count_al = stq_count + total_acc;

  for (genvar e = 0; e < SQ; e++) begin : g_st
    logic [NDIS-1:0] sel;
    for (genvar i = 0; i < NDIS; i++) begin : g_p
      assign sel[i] = acc[i] && stq_head + RIW'(stq_count) + RIW'(rank[i]) == RIW'(e);
    end
    always_comb begin
      st_ev[e]    = '0;
      st_ev[e].go = |sel;
      for (int i = NDIS - 1; i >= 0; i--) begin
        if (sel[i]) begin
          st_ev[e].rob_idx  = stq_rob_idx[i];
          st_ev[e].rob_flag = stq_rob_flag[i];
          st_ev[e].br_mask  = stq_br_mask[i];
        end
      end
    end
  end

endmodule

`default_nettype wire
