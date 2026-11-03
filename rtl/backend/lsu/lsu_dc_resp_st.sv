// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_dcache2lsu_stq + wake_store_replays_on_mshr_fill)
`default_nettype none

// E: DCache store responses -> per-entry events; MSHR-fill wake-up of the committed stores' replay waits.
module lsu_dc_resp_st
  import lsu_pkg::*;
(
  input  logic [NST-1:0]    rsp_valid,
  input  logic [31:0]       rsp_req_id [NST],
  input  logic [1:0]        rsp_replay [NST],
  input  logic              fill_valid,
  input  logic [LINEW-1:0]  fill_line,
  input  logic [RIW-1:0]    stq_head,
  input  logic [RCW-1:0]    stq_count,
  input  logic [RCW-1:0]    stq_ccount,            // after this cycle's commits
  input  st_state_t         st_q       [SQ],
  input  st_state_t         st_dc      [SQ],       // state after the response phase
  input  logic [RWW-1:0]    wait_dc    [SQ],       // replay wait after the response phase
  input  stq_fld_t          fld_q      [SQ],
  input  stq_fld_t          fld_e      [SQ],       // replay type after the response
  output stq_dc_t           ev         [SQ],
  output logic [SQ-1:0]     wk_go
);

  // ---- 1. responses: req_id is the STQ index ----
  logic [SQW-1:0] sidx [NST];
  logic [NST-1:0] base_ok, eff, is_hit;
  always_comb begin
    for (int i = 0; i < NST; i++) begin
      sidx[i]    = rsp_req_id[i][SQW-1:0];
      base_ok[i] = rsp_valid[i] && rsp_req_id[i][31:SQW] == '0 && st_q[sidx[i]] == ST_WAIT_DCACHE_RESP;
      is_hit[i]  = rsp_replay[i] == REPLAY_HIT;
    end
    for (int i = 0; i < NST; i++) begin
      eff[i] = base_ok[i];
      for (int j = 0; j < i; j++) if (eff[j] && sidx[j] == sidx[i]) eff[i] = 1'b0;
    end
  end
  for (genvar e = 0; e < SQ; e++) begin : g_entry
    logic [NST-1:0] sel;
    for (genvar i = 0; i < NST; i++) begin : g_p
      assign sel[i] = eff[i] && sidx[i] == SQW'(e);
    end
    always_comb begin
      ev[e] = '0;
      for (int i = NST - 1; i >= 0; i--) begin
        if (sel[i]) begin
          ev[e].go  = 1'b1;
          ev[e].hit = is_hit[i];
          ev[e].rp  = rsp_replay[i];
        end
      end
    end
  end

  // ---- 2. MSHR fill wake-up over the min(commit_count, count) oldest stores (head order) ----
  logic [RN-1:0]  cand_slot, in_cc, cand_pos, hit_pos, full_pos, wake_hit_pos, cand_full_pos, wake_full_pos, wake_slot;
  logic [RN-1:0]  line_hit, full_slot;
  logic [RCW-1:0] rank_full [RN];
  logic [RCW-1:0] cc_count;
  assign cc_count = stq_ccount > stq_count ? stq_count : stq_ccount;
  for (genvar e = 0; e < SQ; e++) begin : g_slot
    assign cand_slot[e] = fill_valid && st_dc[e] == ST_COMMITTED && wait_dc[e] != '0;
    assign in_cc[e]     = cc_count > RCW'(e);
    assign line_hit[e]  = fld_e[e].replay == REPLAY_MSHR_HIT && fld_q[e].paddr[31:LINE_LO] == fill_line;
    assign full_slot[e] = fld_e[e].replay == REPLAY_MSHR_FULL;
  end
  assign cand_pos      = rotr_rn(cand_slot, stq_head) & in_cc;
  assign hit_pos       = rotr_rn(line_hit, stq_head);
  assign full_pos      = rotr_rn(full_slot, stq_head);
  assign wake_hit_pos  = cand_pos & hit_pos;
  assign cand_full_pos = cand_pos & full_pos;
  lsu_rank #(.N(RN), .CW(RCW)) u_rank_full (.bits(cand_full_pos), .rank(rank_full));
  for (genvar q = 0; q < RN; q++) begin : g_full
    assign wake_full_pos[q] = cand_full_pos[q] && rank_full[q] < RCW'(NST);
  end
  assign wake_slot = rotl_rn(wake_hit_pos | wake_full_pos, stq_head);
  assign wk_go     = wake_slot;

endmodule

`default_nettype wire
