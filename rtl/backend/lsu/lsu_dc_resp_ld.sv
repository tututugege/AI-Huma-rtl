// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_dcache2lsu_ldq + wake_load_replays_on_mshr_fill)
`default_nettype none

// D: DCache load responses -> per-entry events; MSHR-fill wake-up of the wait_dcache replay counters;
// ReadyToWb entries of the wait_dcache window move to the finish queue.
module lsu_dc_resp_ld
  import lsu_pkg::*;
(
  input  logic [NLD-1:0]    rsp_valid,
  input  logic [31:0]       rsp_req_id [NLD],
  input  logic [31:0]       rsp_data   [NLD],
  input  logic [1:0]        rsp_replay [NLD],
  input  logic              fill_valid,
  input  logic [LINEW-1:0]  fill_line,
  input  lsu_ring_t         wdc_q,
  input  logic [GENW-1:0]   wd_gen_q   [RN],
  input  logic [RWW-1:0]    wd_wait_q  [RN],
  input  logic [RCW-1:0]    fin_count_c,           // finish queue count after the MMIO response
  input  ld_state_t         ld_st_q    [LQ],
  input  ld_state_t         ld_st_rsp  [LQ],       // state after this response phase (window scan)
  input  ldq_fld_t          fld_q      [LQ],
  input  ldq_fld_t          fld_e      [LQ],       // replay type after the response
  output ldq_dc_t           ev         [LQ],
  output logic [RN-1:0]     wd_set,                // wait_dcache slot: replay wait written ...
  output logic [RWW-1:0]    wd_set_val [RN],       // ... with this value
  output logic [RN-1:0]     wd_clr,                // wait_dcache slot: wake-up clears the wait
  output lsu_rop_t          wdc_op,
  output lsu_rop_t          fin_op
);

  // ---- 1. responses: one wait_dcache slot per port, checked against the request generation ----
  logic [RIW-1:0] widx [NLD], lidx [NLD];
  logic [NLD-1:0] base_ok, eff, is_hit;
  logic [31:0]    hit_data [NLD];

  always_comb begin
    for (int i = 0; i < NLD; i++) begin
      widx[i]     = rsp_req_id[i][RIW-1:0];
      lidx[i]     = wdc_q.idx[widx[i]];
      base_ok[i]  = rsp_valid[i] && !rsp_req_id[i][31] && wdc_q.valid[widx[i]] &&
                    wd_gen_q[widx[i]] == rsp_req_id[i][RIW+GENW-1:RIW] && ld_st_q[lidx[i]] == LD_WAIT_DCACHE_RESP;
      is_hit[i]   = rsp_replay[i] == REPLAY_HIT;
      hit_data[i] = extract_data(rsp_data[i], fld_q[lidx[i]].paddr[1:0], fld_q[lidx[i]].func3);
    end
  end
  // a second response for an entry that the first one already moved out of WaitDcacheResp is a no-op in C++
  always_comb begin
    for (int i = 0; i < NLD; i++) begin
      eff[i] = base_ok[i];
      for (int j = 0; j < i; j++) if (eff[j] && lidx[j] == lidx[i]) eff[i] = 1'b0;
    end
  end

  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [NLD-1:0] sel;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign sel[i] = eff[i] && lidx[i] == RIW'(e);
    end
    always_comb begin
      ev[e] = '0;
      for (int i = NLD - 1; i >= 0; i--) begin
        if (sel[i]) begin
          ev[e].go   = 1'b1;
          ev[e].hit  = is_hit[i];
          ev[e].rp   = rsp_replay[i];
          ev[e].data = hit_data[i];
        end
      end
    end
  end
  // replay wait written to the slot: MSHR_HIT / MSHR_FULL wait 4 cycles, CONFLICT and a hit none
  for (genvar s = 0; s < RN; s++) begin : g_wait
    logic [NLD-1:0] sel;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign sel[i] = eff[i] && !is_hit[i] && widx[i] == RIW'(s);
    end
    always_comb begin
      wd_set[s]     = |sel;
      wd_set_val[s] = '0;
      for (int i = NLD - 1; i >= 0; i--) if (sel[i]) wd_set_val[s] = rsp_replay[i][1] ? REPLAY_WAIT : '0;
    end
  end

  // ---- 2. MSHR fill wake-up over the first WIN wait_dcache entries ----
  logic [WIN-1:0] valid_w, cand_wake, wake_hit, cand_full, wake_full, cand_fin, app_fin;
  logic [RIW-1:0] idx_w [WIN], slot_w [WIN];
  logic [RCW-1:0] rank_full [WIN], rank_fin [WIN];
  logic [RWW-1:0] wait_r [WIN];                    // wait after the response phase

  lsu_ring_win u_win (.ring(wdc_q), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_win
    assign slot_w[p]    = wdc_q.head + RIW'(p);
    assign wait_r[p]    = wd_set[slot_w[p]] ? wd_set_val[slot_w[p]] : wd_wait_q[slot_w[p]];
    assign cand_wake[p] = fill_valid && valid_w[p] && wait_r[p] != '0 && ld_st_rsp[idx_w[p]] == LD_READY_TO_ISSUE;
    assign wake_hit[p]  = cand_wake[p] && fld_e[idx_w[p]].replay == REPLAY_MSHR_HIT &&
                          fld_q[idx_w[p]].paddr[31:LINE_LO] == fill_line;
    assign cand_full[p] = cand_wake[p] && fld_e[idx_w[p]].replay == REPLAY_MSHR_FULL;
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_full (.bits(cand_full), .rank(rank_full));
  for (genvar p = 0; p < WIN; p++) begin : g_full
    assign wake_full[p] = cand_full[p] && rank_full[p] < RCW'(NLD);
  end
  for (genvar s = 0; s < RN; s++) begin : g_clr
    logic [WIN-1:0] by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p] = (wake_hit[p] || wake_full[p]) && slot_w[p] == RIW'(s);
    end
    assign wd_clr[s] = |by_pos;
  end

  // ---- 3. ReadyToWb entries move to the finish queue (while it has room) and leave wait_dcache ----
  for (genvar p = 0; p < WIN; p++) begin : g_fin
    assign cand_fin[p] = valid_w[p] && ld_st_rsp[idx_w[p]] == LD_READY_TO_WB;
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_fin (.bits(cand_fin), .rank(rank_fin));
  for (genvar p = 0; p < WIN; p++) begin : g_app
    assign app_fin[p] = cand_fin[p] && fin_count_c + rank_fin[p] < RCW'(LQ);
  end
  logic [WIN-1:0][RIW-1:0] idx_pk;
  for (genvar p = 0; p < WIN; p++) begin : g_pk
    assign idx_pk[p] = idx_w[p];
  end
  assign fin_op = rop_app(app_fin, idx_pk);
  assign wdc_op = rop_kp(valid_w & ~app_fin);

endmodule

`default_nettype wire
