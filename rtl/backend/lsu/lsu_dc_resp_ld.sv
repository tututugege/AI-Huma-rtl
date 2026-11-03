// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_dcache2lsu_ldq + wake_load_replays_on_mshr_fill)
`default_nettype none

module lsu_dc_resp_ld
  import lsu_pkg::*;
(
  input  logic [NLD-1:0]    rsp_valid,
  input  logic [31:0]       rsp_req_id [NLD],
  input  logic [31:0]       rsp_data   [NLD],
  input  logic [1:0]        rsp_replay [NLD],
  input  logic              fill_valid,
  input  logic [LINEW-1:0]  fill_line,
  input  lsu_ring_t         wdc_i,
  input  logic [GENW-1:0]   wd_gen     [RN],
  input  logic [RWW-1:0]    wd_wait_i  [RN],
  input  lsu_ring_t         finish_i,
  input  ld_state_t         ld_st_i     [LQ],
  input  logic [31:0]       ld_paddr    [LQ],
  input  logic [2:0]        ld_func3    [LQ],
  input  logic [31:0]       ld_result_i [LQ],
  input  logic [1:0]        ld_replay_i [LQ],
  output lsu_ring_t         wdc_o,
  output logic [RWW-1:0]    wd_wait_o  [RN],
  output lsu_ring_t         finish_o,
  output ld_state_t         ld_st_o     [LQ],
  output logic [31:0]       ld_result_o [LQ],
  output logic [1:0]        ld_replay_o [LQ]
);

  // ---- 1. responses: one wait_dcache slot per port, checked against the request generation ----
  logic [RIW-1:0] widx [NLD], lidx [NLD];
  logic [NLD-1:0] base_ok, eff, is_hit;
  logic [31:0]    hit_data [NLD];

  always_comb begin
    for (int i = 0; i < NLD; i++) begin
      widx[i]     = rsp_req_id[i][RIW-1:0];
      lidx[i]     = wdc_i.idx[widx[i]];
      base_ok[i]  = rsp_valid[i] && !rsp_req_id[i][31] && wdc_i.valid[widx[i]] &&
                    wd_gen[widx[i]] == rsp_req_id[i][RIW+GENW-1:RIW] && ld_st_i[lidx[i]] == LD_WAIT_DCACHE_RESP;
      is_hit[i]   = rsp_replay[i] == REPLAY_HIT;
      hit_data[i] = extract_data(rsp_data[i], ld_paddr[lidx[i]][1:0], ld_func3[lidx[i]]);
    end
  end
  // a second response for an entry that the first one already moved out of WaitDcacheResp is a no-op in C++
  always_comb begin
    for (int i = 0; i < NLD; i++) begin
      eff[i] = base_ok[i];
      for (int j = 0; j < i; j++) if (eff[j] && lidx[j] == lidx[i]) eff[i] = 1'b0;
    end
  end

  ld_state_t      ld_st_v1     [LQ];
  logic [1:0]     ld_replay_v1 [LQ];
  logic [RWW-1:0] wd_wait_v1   [RN];
  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [NLD-1:0] sel;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign sel[i] = eff[i] && lidx[i] == RIW'(e);
    end
    always_comb begin
      ld_st_v1[e]     = ld_st_i[e];
      ld_result_o[e]  = ld_result_i[e];
      ld_replay_v1[e] = ld_replay_i[e];
      for (int i = NLD - 1; i >= 0; i--) begin
        if (sel[i]) begin
          ld_st_v1[e]     = is_hit[i] ? LD_READY_TO_WB : LD_READY_TO_ISSUE;
          ld_replay_v1[e] = rsp_replay[i];
          if (is_hit[i]) ld_result_o[e] = hit_data[i];
        end
      end
    end
  end
  for (genvar s = 0; s < RN; s++) begin : g_wait
    logic [NLD-1:0] sel;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign sel[i] = eff[i] && !is_hit[i] && widx[i] == RIW'(s);
    end
    always_comb begin
      wd_wait_v1[s] = wd_wait_i[s];
      for (int i = NLD - 1; i >= 0; i--)
        if (sel[i]) wd_wait_v1[s] = rsp_replay[i][1] ? REPLAY_WAIT : '0;   // MSHR_HIT / MSHR_FULL wait 4 cycles
    end
  end

  // ---- 2. MSHR fill wake-up over the first WIN wait_dcache entries ----
  logic [WIN-1:0] valid_w, cand_wake, wake_hit, cand_full, wake_full, cand_fin, app_fin;
  logic [RIW-1:0] idx_w [WIN], slot_w [WIN];
  logic [RCW-1:0] rank_full [WIN], rank_fin [WIN];

  lsu_ring_win u_win (.ring(wdc_i), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_slot
    assign slot_w[p] = wdc_i.head + RIW'(p);
  end

  for (genvar p = 0; p < WIN; p++) begin : g_win
    assign cand_wake[p] = fill_valid && valid_w[p] && wd_wait_v1[slot_w[p]] != '0 &&
                          ld_st_v1[idx_w[p]] == LD_READY_TO_ISSUE;
    assign wake_hit[p]  = cand_wake[p] && ld_replay_v1[idx_w[p]] == REPLAY_MSHR_HIT &&
                          ld_paddr[idx_w[p]][31:LINE_LO] == fill_line;
    assign cand_full[p] = cand_wake[p] && ld_replay_v1[idx_w[p]] == REPLAY_MSHR_FULL;
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_full (.bits(cand_full), .rank(rank_full));
  for (genvar p = 0; p < WIN; p++) begin : g_full
    assign wake_full[p] = cand_full[p] && rank_full[p] < RCW'(NLD);
  end
  for (genvar s = 0; s < RN; s++) begin : g_wait_o
    logic [WIN-1:0] by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p] = (wake_hit[p] || wake_full[p]) && slot_w[p] == RIW'(s);
    end
    assign wd_wait_o[s] = (|by_pos) ? '0 : wd_wait_v1[s];
  end

  // ---- 3. ReadyToWb entries move to the finish queue (while it has room) and leave wait_dcache ----
  for (genvar p = 0; p < WIN; p++) begin : g_fin
    assign cand_fin[p] = valid_w[p] && ld_st_v1[idx_w[p]] == LD_READY_TO_WB;
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_fin (.bits(cand_fin), .rank(rank_fin));
  for (genvar p = 0; p < WIN; p++) begin : g_app
    assign app_fin[p] = cand_fin[p] && finish_i.count + rank_fin[p] < RCW'(LQ);
  end

  lsu_ring_app #(.NA(WIN)) u_fin (.ring_i(finish_i), .app_en(app_fin), .app_idx(idx_w), .ring_o(finish_o));
  lsu_ring_kill_pop u_pop (.ring_i(wdc_i), .keep_w(valid_w & ~app_fin), .ring_o(wdc_o));

  assign ld_st_o     = ld_st_v1;
  assign ld_replay_o = ld_replay_v1;

endmodule

`default_nettype wire
