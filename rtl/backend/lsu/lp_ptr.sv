// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (stq_head / stq_count / stq_ccount: comb_stq_commit_p, comb_dis2lsu_p,
`default_nettype none

// STQ pointers of the staged LSU.  Registers: head, head_flag, count (allocated), ccount (committed, not retired);
// stq_commit = head + ccount is derived.  Rule chain of a cycle:
//   count : + allocations (P10) -> rob flush keeps min(ccount, count) / mispredict cuts at the first hit (P11) ->
// - retired (P14)
//   ccount: + commits (P1, saturating) -> flush: min(ccount, count) / mispredict: not above the cut count -> - retired
module lp_ptr
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
  import ttg_util_pkg::ttg_rob_younger;
  import dis_pkg::AMO_LR;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [ROBW-1:0]     dec_rob_idx,
  input  logic                dec_rob_flag,
  // P1 commit
  input  logic [NCM-1:0]      cm_valid,
  input  logic [4:0]          cm_type [NCM],
  input  logic [4:0]          cm_amo_op [NCM],
  input  logic [SQW-1:0]      cm_stq_idx [NCM],
  input  logic [SQ-1:0]       wbd_vec,
  output logic [SQ-1:0]       cm_go,
  // P10 allocation
  input  logic [NDIS-1:0]     al_req,
  output logic [SQ-1:0]       al_v,
  output logic [SQ-1:0][NDIS-1:0] al_slot,
  // P11 mispredict cut (entry ROB pointer)
  input  logic [ROBW-1:0]     sq_rob_idx [SQ],
  input  logic [SQ-1:0]       sq_rob_flag,
  // P14 retire
  input  logic [SQ-1:0]       done_q_vec,    // done bits as registered
  output logic [SQ-1:0]       ev_ret,
  // state / views
  output logic [SQW-1:0]      head_q,
  output logic                head_flag_q,
  output logic [CNTW-1:0]     count_q,
  output logic [CNTW-1:0]     ccount_q,
  output logic [SQ-1:0]       alive_w,       // inside [head, head + count) at the start of the cycle
  output logic [SQ-1:0]       win4,          // rank < min(ccount after P1, count)
  output logic [SQ-1:0]       win13,         // rank < min(ccount, count) after P11
  output logic [SQ-1:0]       alive_post,    // inside the final window
  output logic [CNTW-1:0]     count_flushed, // count after the rob-flush step only (uncached unit)
  output logic [SQ-1:0]       alive_fl       // rank < count after P11 (srp / unit views)
);

  function automatic logic [SQ-1:0] ring_mask(input logic [SQW-1:0] head, input logic [CNTW-1:0] cnt);
    logic [SQ-1:0] thermo;
    thermo = (cnt >= CNTW'(SQ)) ? '1 : ~('1 << cnt[SQW-1:0]);
    return SQ'(rotl64(64'(thermo), head));
  endfunction

  // ---- P1: parallel store commit matching ----
  // The stores of a commit group are consecutive in program order, hence consecutive in the STQ: all of them hit
  // commit_ptr + (stores before them) as soon as the first one hits commit_ptr.  They are accepted as a prefix while
  // their data / address is written back.
  logic [NCM-1:0]  cm_store, cm_match, first_st;
  logic [SQW-1:0]  commit_ptr;
  logic [CNTW-1:0] ccount_cm, n_m;
  logic            first_ok, wb_pre;
  assign commit_ptr = head_q + SQW'(ccount_q);
  always_comb begin
    first_ok = 1'b0;
    wb_pre   = 1'b1;
    for (int i = 0; i < NCM; i++) begin
      cm_store[i] = cm_valid[i] && (cm_type[i] == 5'd6 || (cm_type[i] == 5'd18 && cm_amo_op[i] != AMO_LR));
      first_st[i] = cm_store[i];
      for (int k = 0; k < i; k++) first_st[i] = first_st[i] && !cm_store[k];
      first_ok = first_ok || (first_st[i] && cm_stq_idx[i] == commit_ptr);
    end
    for (int i = 0; i < NCM; i++) begin
      wb_pre = wb_pre && (!cm_store[i] || wbd_vec[cm_stq_idx[i]]);
      cm_match[i] = cm_store[i] && first_ok && wb_pre;
    end
    n_m = '0;
    for (int i = 0; i < NCM; i++) n_m = n_m + CNTW'(cm_match[i]);
  end
  assign ccount_cm = (ccount_q + n_m > CNTW'(SQ)) ? CNTW'(SQ) : ccount_q + n_m;
  for (genvar s = 0; s < SQ; s++) begin : g_cm
    logic [NCM-1:0] by_port;
    for (genvar i = 0; i < NCM; i++) begin : g_p
      assign by_port[i] = cm_match[i] && cm_stq_idx[i] == SQW'(s);
    end
    assign cm_go[s] = |by_port;
  end

  // ---- P10: dispatch slot i takes the entry tail + (number of requests before it) ----
  logic [CNTW-1:0] n_req [NDIS+1];
  logic [CNTW-1:0] count_al;
  // (the number of requests before slot i: a popcount of the lower requests, not a chain of adders)
  for (genvar i = 0; i <= NDIS; i++) begin : g_nreq
    localparam logic [NDIS-1:0] BELOW = NDIS'((64'(1) << i) - 64'(1));
    ttg_popcount #(.N(NDIS), .CW(CNTW)) u_n (.bits(al_req & BELOW), .count(n_req[i]));
  end
  assign count_al = count_q + n_req[NDIS];
  for (genvar s = 0; s < SQ; s++) begin : g_al
    logic [NDIS-1:0] hit;
    for (genvar i = 0; i < NDIS; i++) begin : g_p
      assign hit[i] = al_req[i] && (head_q + SQW'(count_q) + SQW'(n_req[i])) == SQW'(s);
    end
    assign al_slot[s] = hit;
    assign al_v[s] = |hit;
  end

  // ---- P11: rob flush keeps committed stores, mispredict cuts STQ at first uncommitted entry younger than branch ----
  logic [CNTW-1:0] keep_committed, count_m, count_fl;
  logic [SQ-1:0] hit_slot, hit_pos, hit_first;
  logic [63:0]   hit_rot;
  logic          any_hit;
  logic [CNTW-1:0] count_fm;
  assign keep_committed = ccount_cm > count_q ? count_q : ccount_cm;
  assign count_flushed = flush ? keep_committed : count_al;
  assign count_fm = flush ? keep_committed : count_q;
  for (genvar s = 0; s < SQ; s++) begin : g_hit
    assign hit_slot[s] = ttg_rob_younger(sq_rob_idx[s], sq_rob_flag[s], dec_rob_idx, dec_rob_flag);
  end
  assign hit_rot = rotr64(64'(hit_slot), head_q);
  for (genvar j = 0; j < SQ; j++) begin : g_pos
    assign hit_pos[j] = hit_rot[j] && (CNTW'(j) >= ccount_cm);
  end
  ttg_first_set #(.N(SQ)) u_first (.req(hit_pos), .onehot(hit_first), .any(any_hit));
  logic [SQW-1:0] first_ix;
  ttg_onehot_to_idx #(.N(SQ)) u_fix (.onehot(hit_first), .idx(first_ix));
  always_comb begin
    count_m = count_fm;
    if (any_hit && CNTW'(first_ix) < count_fm) count_m = CNTW'(first_ix);
  end
  assign count_fl = mispred ? count_m : count_flushed;

  // ---- P14: up to NRET Done stores at the head retire ----
  logic [NRET-1:0] ret_ok;
  logic [CNTW-1:0] n_ret;
  logic [SQW:0]    head_sum;
  always_comb begin
    for (int k = 0; k < NRET; k++) begin
      ret_ok[k] = ccount_q > CNTW'(k) && count_q > CNTW'(k) && done_q_vec[head_q + SQW'(k)];
    end
    n_ret = '0;
    if (ret_ok[0]) n_ret = CNTW'(1);
    if (ret_ok[0] && ret_ok[1]) n_ret = CNTW'(2);
    if (ret_ok[0] && ret_ok[1] && ret_ok[2]) n_ret = CNTW'(3);
    if (&ret_ok) n_ret = CNTW'(4);
    head_sum = {1'b0, head_q} + n_ret[SQW:0];
  end
  logic [SQ-1:0] ret_thermo;
  assign ret_thermo = (n_ret == '0) ? '0 : ~('1 << n_ret[SQW-1:0]);
  assign ev_ret = SQ'(rotl64(64'(ret_thermo), head_q));

  // ---- views ----
  logic [SQW-1:0] head_d;
  logic [CNTW-1:0] count_d, ccount_d;
  logic [SQ-1:0] cmt_reg_mask, cmt_mask, uncmt_hit_slot;
  assign head_d = head_sum[SQW-1:0];
  assign count_d = count_fl - n_ret;
  assign ccount_d = ccount_cm - n_ret;
  assign alive_w = ring_mask(head_q, count_q);
  assign cmt_reg_mask = ring_mask(head_q, ccount_q > count_q ? count_q : ccount_q);
  assign win4  = cmt_reg_mask;
  assign win13 = cmt_reg_mask;
  assign cmt_mask       = ring_mask(head_q, ccount_cm);
  assign uncmt_hit_slot = hit_slot & ~cmt_mask;
  assign alive_post = alive_w & ~ev_ret & ~(mispred ? uncmt_hit_slot : '0) & (flush ? cmt_mask : '1);
  assign alive_fl   = alive_w & ~(mispred ? uncmt_hit_slot : '0) & (flush ? cmt_mask : '1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q <= '0;
      head_flag_q <= 1'b0;
      count_q <= '0;
      ccount_q <= '0;
    end else begin
      head_q <= head_d;
      head_flag_q <= head_sum[SQW] ? !head_flag_q : head_flag_q;
      count_q <= count_d;
      ccount_q <= ccount_d;
    end
  end

endmodule

`default_nettype wire
