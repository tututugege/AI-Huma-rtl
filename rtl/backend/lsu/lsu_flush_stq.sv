// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_flush: STQ part -- rob flush, mispredict truncation, br_mask clear)
`default_nettype none

module lsu_flush_stq
  import lsu_pkg::*;
(
  input  logic             flush,
  input  logic             mispred,
  input  logic [BRW-1:0]   dec_br_mask,
  input  logic [BRW-1:0]   clear_mask,
  input  logic [RIW-1:0]   stq_head,             // head and count after this cycle's allocations
  input  logic [RCW-1:0]   stq_count_i,
  input  logic [RCW-1:0]   stq_ccount_i,
  input  logic [RIW-1:0]   stq_head_q,           // cycle-start window: selects the entries whose br_mask is cleared
  input  logic [RCW-1:0]   stq_count_q,
  input  logic [BRW-1:0]   st_br_mask_i [SQ],
  output logic [RCW-1:0]   count_flushed,        // count after the rob-flush step (before the mispredict step)
  output logic [RCW-1:0]   stq_count_o,
  output logic [RCW-1:0]   stq_ccount_o,
  output logic [BRW-1:0]   st_br_mask_o [SQ]
);

  logic [RCW-1:0] keep_committed, count_m;
  logic [SQ-1:0]  hit_slot, hit_pos, hit_first, in_clear_win;
  /* verilator lint_off UNUSEDSIGNAL */  // first_set "any" not needed: count_m defaults to count_flushed
  logic           any_hit;
  /* verilator lint_on UNUSEDSIGNAL */

  assign keep_committed = stq_ccount_i > stq_count_i ? stq_count_i : stq_ccount_i;
  assign count_flushed  = flush ? keep_committed : stq_count_i;

  // mispredict: the STQ is cut at the first (oldest) entry whose br_mask hits
  logic [SQ-1:0] hit_slot_pos;
  logic [RCW-1:0] ccount_flushed;
  for (genvar s = 0; s < SQ; s++) begin : g_slot
    assign hit_slot[s]      = (st_br_mask_i[s] & dec_br_mask) != '0;
    assign in_clear_win[s]  = stq_alive(RIW'(s), stq_head_q, stq_count_q);
    assign st_br_mask_o[s]  = in_clear_win[s] ? st_br_mask_i[s] & ~clear_mask : st_br_mask_i[s];
  end
  assign hit_slot_pos = rotr_rn(hit_slot, stq_head);
  for (genvar j = 0; j < SQ; j++) begin : g_pos
    assign hit_pos[j] = hit_slot_pos[j] && count_flushed > RCW'(j);
  end
  ttg_first_set #(.N(SQ)) u_first (.req(hit_pos), .onehot(hit_first), .any(any_hit));

  always_comb begin
    count_m = count_flushed;
    for (int j = 0; j < SQ; j++) if (hit_first[j]) count_m = RCW'(j);
  end

  assign ccount_flushed = flush ? keep_committed : stq_ccount_i;
  assign stq_count_o    = mispred ? count_m : count_flushed;
  assign stq_ccount_o   = (mispred && ccount_flushed > count_m) ? count_m : ccount_flushed;

endmodule

`default_nettype wire
