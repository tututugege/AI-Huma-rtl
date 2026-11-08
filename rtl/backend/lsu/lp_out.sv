// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu::comb_lsu2dis_p / comb_lsu2rob_p (free LDQ entries, STQ tail, free counts)
`default_nettype none

// Views of the LSU queues for dispatch (free LDQ entries and their indices, STQ tail / free count) and the ROB.
module lp_out
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic [LQ-1:0]       empty_w,
  input  logic [SQW-1:0]      head_q,
  input  logic                head_flag_q,
  input  logic [CNTW-1:0]     count_q,
  input  logic [CNTW-1:0]     ccount_q,
  output logic [SQW-1:0]      o_stq_tail,
  output logic                o_stq_tail_flag,
  output logic [CNTW-1:0]     o_stq_free,
  output logic [CNTW-1:0]     o_ldq_free,
  output logic [NDIS-1:0]     o_ldq_alloc_valid,
  output logic [LQW-1:0]      o_ldq_alloc_idx [NDIS],
  output logic                o_committed_store_pending
);

  /* verilator lint_off UNUSEDSIGNAL */  // primitive output not needed here
  logic [LQ-1:0] ld_free_oh [NDIS];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [LQW-1:0] ld_free_ix [NDIS];
  logic [NDIS-1:0] ld_free_v;
  logic [LQW:0] ld_free_cnt;
  lp_pickn #(.N(LQ), .K(NDIS)) u_alloc (.vec(empty_w), .onehot(ld_free_oh), .idx(ld_free_ix), .v(ld_free_v));
  ttg_popcount #(.N(LQ), .CW(LQW+1)) u_cnt (.bits(empty_w), .count(ld_free_cnt));
  assign o_ldq_alloc_valid = ld_free_v;
  assign o_ldq_free = CNTW'(ld_free_cnt);
  always_comb begin
    for (int i = 0; i < NDIS; i++) o_ldq_alloc_idx[i] = ld_free_ix[i];
  end
  logic [CNTW:0] tail_sum;
  assign tail_sum = (CNTW+1)'(head_q) + (CNTW+1)'(count_q);
  assign o_stq_tail = head_q + SQW'(count_q);
  assign o_stq_tail_flag = tail_sum >= (CNTW+1)'(SQ) ? !head_flag_q : head_flag_q;
  assign o_stq_free = CNTW'(SQ) - count_q;
  assign o_committed_store_pending = ccount_q != '0;

endmodule

`default_nettype wire
