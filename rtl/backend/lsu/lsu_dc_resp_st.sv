// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_dcache2lsu_stq + wake_store_replays_on_mshr_fill)
`default_nettype none

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
  input  logic [RCW-1:0]    stq_ccount,
  input  st_state_t         st_st_i     [SQ],
  input  logic [1:0]        st_replay_i [SQ],
  input  logic [RWW-1:0]    st_wait_i   [SQ],
  input  logic [31:0]       st_paddr    [SQ],
  output st_state_t         st_st_o     [SQ],
  output logic [1:0]        st_replay_o [SQ],
  output logic [RWW-1:0]    st_wait_o   [SQ]
);

  // ---- 1. responses: req_id is the STQ index ----
  logic [SQW-1:0] sidx [NST];
  logic [NST-1:0] base_ok, eff, is_hit;

  always_comb begin
    for (int i = 0; i < NST; i++) begin
      sidx[i]    = rsp_req_id[i][SQW-1:0];
      base_ok[i] = rsp_valid[i] && rsp_req_id[i][31:SQW] == '0 && st_st_i[sidx[i]] == ST_WAIT_DCACHE_RESP;
      is_hit[i]  = rsp_replay[i] == REPLAY_HIT;
    end
    for (int i = 0; i < NST; i++) begin
      eff[i] = base_ok[i];
      for (int j = 0; j < i; j++) if (eff[j] && sidx[j] == sidx[i]) eff[i] = 1'b0;
    end
  end

  st_state_t      st_v1        [SQ];
  logic [RWW-1:0] wait_v1      [SQ];
  logic [SQ-1:0]  committed_v1, line_hit_v1, full_v1, waiting_v1;
  for (genvar e = 0; e < SQ; e++) begin : g_entry
    logic [NST-1:0] sel;
    for (genvar i = 0; i < NST; i++) begin : g_p
      assign sel[i] = eff[i] && sidx[i] == SQW'(e);
    end
    always_comb begin
      st_v1[e]        = st_st_i[e];
      st_replay_o[e]  = st_replay_i[e];
      wait_v1[e]      = st_wait_i[e];
      for (int i = NST - 1; i >= 0; i--) begin
        if (sel[i]) begin
          st_v1[e]       = is_hit[i] ? ST_DONE : ST_COMMITTED;
          st_replay_o[e] = rsp_replay[i];
          wait_v1[e]     = (!is_hit[i] && rsp_replay[i][1]) ? REPLAY_WAIT : '0;
        end
      end
    end
    assign committed_v1[e] = st_v1[e] == ST_COMMITTED;
    assign waiting_v1[e]   = wait_v1[e] != '0;
    assign line_hit_v1[e]  = st_replay_o[e] == REPLAY_MSHR_HIT && st_paddr[e][31:LINE_LO] == fill_line;
    assign full_v1[e]      = st_replay_o[e] == REPLAY_MSHR_FULL;
  end

  // ---- 2. MSHR fill wake-up over the min(commit_count, count) oldest stores (head order) ----
  logic [RN-1:0]  cand_slot, in_cc, cand_pos, hit_pos, full_pos, wake_hit_pos, cand_full_pos, wake_full_pos, wake_slot;
  logic [RCW-1:0] rank_full [RN];
  logic [RCW-1:0] cc_count;

  assign cc_count = stq_ccount > stq_count ? stq_count : stq_ccount;
  for (genvar e = 0; e < SQ; e++) begin : g_slot
    assign cand_slot[e] = fill_valid && committed_v1[e] && waiting_v1[e];
    assign in_cc[e]     = cc_count > RCW'(e);
  end
  assign cand_pos      = rotr_rn(cand_slot, stq_head) & in_cc;
  assign hit_pos       = rotr_rn(line_hit_v1, stq_head);
  assign full_pos      = rotr_rn(full_v1, stq_head);
  assign wake_hit_pos  = cand_pos & hit_pos;
  assign cand_full_pos = cand_pos & full_pos;
  lsu_rank #(.N(RN), .CW(RCW)) u_rank_full (.bits(cand_full_pos), .rank(rank_full));
  for (genvar q = 0; q < RN; q++) begin : g_full
    assign wake_full_pos[q] = cand_full_pos[q] && rank_full[q] < RCW'(NST);
  end
  assign wake_slot = rotl_rn(wake_hit_pos | wake_full_pos, stq_head);

  for (genvar e = 0; e < SQ; e++) begin : g_out
    assign st_st_o[e]   = st_v1[e];
    assign st_wait_o[e] = wake_slot[e] ? '0 : wait_v1[e];
  end

endmodule

`default_nettype wire
