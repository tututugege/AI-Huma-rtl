// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (stq_head/stq_head_flag/stq_count/stq_commit_count: comb_flush, comb_check)
`default_nettype none

// STQ pointers.  Registers: head, head_flag, count (allocated), ccount (committed, not yet retired).
// Per-cycle rule chain (docs/analysis/lsu-structure.md section 2):
//   count : + allocations (K) -> rob flush keeps min(ccount, count) / mispredict truncates at the first hit (L)
//           -> - retired stores (P)
//   ccount: + commits (B) -> flush: min(ccount, count) / mispredict: not above the truncated count (L) -> - retired (P)
// stq_commit = head + ccount is not kept (identity in C++).
module lsu_stq_ptr
  import lsu_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  input  logic             flush,
  input  logic             mispred,
  input  logic [BRW-1:0]   dec_br_mask,
  input  logic [RCW-1:0]   ccount_cm,             // after B
  input  logic [RCW-1:0]   count_al,              // after K
  input  logic [BRW-1:0]   br_al        [SQ],     // entry br_mask after K (mispredict truncation point)
  input  st_state_t        st_nx        [SQ],     // entry state after N (retire scan)
  output logic [RIW-1:0]   head_q,
  output logic             head_flag_q,
  output logic [RCW-1:0]   count_q,
  output logic [RCW-1:0]   ccount_q,
  output logic [RCW-1:0]   count_flushed,         // count after the rob-flush step only
  output logic [RCW-1:0]   count_fl,              // count after the L step
  output logic [RCW-1:0]   ccount_fl,
  output logic [SQ-1:0]    clr_win                // entry inside [head, head + count) at the start of the cycle
);

  // ---- L: rob flush keeps the committed stores, a mispredict cuts the STQ at the first entry whose br_mask hits ----
  logic [RCW-1:0] keep_committed, count_m, ccount_flushed;
  logic [SQ-1:0]  hit_slot, hit_pos, hit_first, hit_slot_pos;
  /* verilator lint_off UNUSEDSIGNAL */  // first_set "any" not needed: count_m defaults to count_flushed
  logic           any_hit;
  /* verilator lint_on UNUSEDSIGNAL */
  assign keep_committed = ccount_cm > count_al ? count_al : ccount_cm;
  assign count_flushed  = flush ? keep_committed : count_al;
  assign ccount_flushed = flush ? keep_committed : ccount_cm;
  for (genvar s = 0; s < SQ; s++) begin : g_slot
    assign hit_slot[s] = (br_al[s] & dec_br_mask) != '0;
    assign clr_win[s]  = stq_alive(RIW'(s), head_q, count_q);
  end
  assign hit_slot_pos = rotr_rn(hit_slot, head_q);
  for (genvar j = 0; j < SQ; j++) begin : g_pos
    assign hit_pos[j] = hit_slot_pos[j] && count_flushed > RCW'(j);
  end
  ttg_first_set #(.N(SQ)) u_first (.req(hit_pos), .onehot(hit_first), .any(any_hit));
  always_comb begin
    count_m = count_flushed;
    for (int j = 0; j < SQ; j++) if (hit_first[j]) count_m = RCW'(j);
  end
  assign count_fl  = mispred ? count_m : count_flushed;
  assign ccount_fl = (mispred && ccount_flushed > count_m) ? count_m : ccount_flushed;

  // ---- P: the Done stores at the head (inside the committed window) retire ----
  logic [RCW-1:0] committed, window, n_retire;
  logic [WIN-1:0] not_done, first_not_done;
  logic [RIW:0]   head_sum;
  /* verilator lint_off UNUSEDSIGNAL */  // first_set "any" not needed: n_retire defaults to the window size
  logic           any_not_done;
  /* verilator lint_on UNUSEDSIGNAL */
  assign committed = ccount_fl > count_fl ? count_fl : ccount_fl;
  assign window    = committed > RCW'(WIN) ? RCW'(WIN) : committed;
  for (genvar p = 0; p < WIN; p++) begin : g_ret
    assign not_done[p] = RCW'(p) >= window || st_nx[head_q + RIW'(p)] != ST_DONE;
  end
  ttg_first_set #(.N(WIN)) u_nd (.req(not_done), .onehot(first_not_done), .any(any_not_done));
  always_comb begin
    n_retire = window;
    for (int p = 0; p < WIN; p++) if (first_not_done[p]) n_retire = RCW'(p);
  end
  assign head_sum = {1'b0, head_q} + n_retire[RIW:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q      <= '0;
      head_flag_q <= 1'b0;
      count_q     <= '0;
      ccount_q    <= '0;
    end else begin
      head_q      <= head_sum[RIW-1:0];
      head_flag_q <= head_sum[RIW] ? !head_flag_q : head_flag_q;
      count_q     <= count_fl - n_retire;
      ccount_q    <= ccount_fl - n_retire;
    end
  end

endmodule

`default_nettype wire
