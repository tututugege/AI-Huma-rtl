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
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [BRW-1:0]      dec_br_mask,
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
  // P11 mispredict cut (entry br_mask after the allocation)
  input  logic [BRW-1:0]      br_al [SQ],
  // P14 retire
  input  logic [SQ-1:0]       done_vec,
  input  logic [SQ-1:0]       done_q_vec,    // done bits as registered (retire reads them with LP_CUT[1])
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

  // ---- P1: the k-th accepted commit must hit the commit pointer advanced by the commits accepted before it ----
  logic [NCM-1:0] cm_store, cm_match;
  logic [SQW-1:0] commit_ptr;
  logic [CNTW-1:0] ccount_cm;
  assign commit_ptr = head_q + SQW'(ccount_q);
  if ((LP_CUT & 64) != 0) begin : g_cm_par
    // parallel form: store i must hit commit_ptr + (stores before it); all stores before it must be accepted
    logic [NCM-1:0] wb_ok;
    logic [CNTW-1:0] n_st [NCM+1];
    always_comb begin
      n_st[0] = '0;
      for (int i = 0; i < NCM; i++) begin
        cm_store[i] = cm_valid[i] && (cm_type[i] == 5'd6 || (cm_type[i] == 5'd18 && cm_amo_op[i] != AMO_LR));
        n_st[i+1] = n_st[i] + CNTW'(cm_store[i]);
        wb_ok[i] = !cm_store[i] || wbd_vec[cm_stq_idx[i]];
        cm_match[i] = cm_store[i] && cm_stq_idx[i] == commit_ptr + SQW'(n_st[i]) &&
                      wbd_vec[cm_stq_idx[i]];
        for (int k = 0; k < i; k++)
          cm_match[i] = cm_match[i] && wb_ok[k] && (!cm_store[k] || cm_stq_idx[k] == commit_ptr + SQW'(n_st[k]));
      end
    end
    // number accepted = leading run of matches among the stores (matches are a prefix of the group's stores)
    logic [CNTW-1:0] n_m;
    always_comb begin
      n_m = '0;
      for (int i = 0; i < NCM; i++) n_m = n_m + CNTW'(cm_match[i]);
    end
    assign ccount_cm = (ccount_q + n_m > CNTW'(SQ)) ? CNTW'(SQ) : ccount_q + n_m;
  end else begin : g_cm_ser
    logic [CNTW-1:0] n_acc [NCM+1];
    always_comb begin
      n_acc[0] = '0;
      for (int i = 0; i < NCM; i++) begin
        cm_store[i] = cm_valid[i] && (cm_type[i] == 5'd6 || (cm_type[i] == 5'd18 && cm_amo_op[i] != AMO_LR));
        cm_match[i] = cm_store[i] && cm_stq_idx[i] == commit_ptr + SQW'(n_acc[i]) && wbd_vec[cm_stq_idx[i]];
        n_acc[i+1] = n_acc[i] + CNTW'(cm_match[i]);
      end
      ccount_cm = (ccount_q + n_acc[NCM] > CNTW'(SQ)) ? CNTW'(SQ) : ccount_q + n_acc[NCM];
    end
  end
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
  always_comb begin
    n_req[0] = '0;
    for (int i = 0; i < NDIS; i++) n_req[i+1] = n_req[i] + CNTW'(al_req[i]);
    count_al = count_q + n_req[NDIS];
  end
  for (genvar s = 0; s < SQ; s++) begin : g_al
    logic [NDIS-1:0] hit;
    for (genvar i = 0; i < NDIS; i++) begin : g_p
      assign hit[i] = al_req[i] && (head_q + SQW'(count_q) + SQW'(n_req[i])) == SQW'(s);
    end
    assign al_slot[s] = hit;
    assign al_v[s] = |hit;
  end

  // ---- P11: rob flush keeps the committed stores, a mispredict cuts the STQ at the first entry whose br_mask hits
  // ----
  logic [CNTW-1:0] keep_committed, count_m, ccount_flushed, ccount_fl, count_fl;
  logic [SQ-1:0] hit_slot, hit_pos, hit_first;
  logic [63:0]   hit_rot;
  logic          any_hit;
  assign keep_committed = ccount_cm > count_al ? count_al : ccount_cm;
  assign count_flushed = flush ? keep_committed : count_al;
  // LP_CUT[8]: committed stores are never cut (a mispredict only cuts younger stores; ccount_cm <= count_q <= count_al)
  assign ccount_flushed = (flush && ((LP_CUT & 256) == 0)) ? keep_committed : ccount_cm;
  for (genvar s = 0; s < SQ; s++) begin : g_hit
    assign hit_slot[s] = (br_al[s] & dec_br_mask) != '0;
  end
  assign hit_rot = rotr64(64'(hit_slot), head_q);
  // LP_L2[10]: the first hit is searched over all positions (no count in front of the search) and compared with
  // count_flushed afterwards.  Equivalent: only positions below count_al hold live entries, so a live hit always
  // comes before any stale one; a first hit at or above count_flushed means no hit inside the window.
  for (genvar j = 0; j < SQ; j++) begin : g_pos
    assign hit_pos[j] = hit_rot[j] && (((LP_L2 & 1024) != 0) || count_flushed > CNTW'(j));
  end
  lp_ffs #(.N(SQ)) u_first (.req(hit_pos), .onehot(hit_first), .any(any_hit));
  logic [SQW-1:0] first_ix;
  ttg_onehot_to_idx #(.N(SQ)) u_fix (.onehot(hit_first), .idx(first_ix));
  always_comb begin
    count_m = count_flushed;
    if ((LP_L2 & 1024) != 0) begin
      if (any_hit && CNTW'(first_ix) < count_flushed) count_m = CNTW'(first_ix);
    end else begin
      for (int j = 0; j < SQ; j++) if (hit_first[j]) count_m = CNTW'(j);
    end
  end
  assign count_fl = mispred ? count_m : count_flushed;
  assign ccount_fl = (mispred && ccount_flushed > count_m && ((LP_CUT & 256) == 0)) ? count_m : ccount_flushed;

  // ---- P14: up to NRET Done stores at the head retire ----
  logic [NRET-1:0] ret_ok;
  logic [CNTW-1:0] n_ret;
  logic [CNTW-1:0] committed;
  logic [SQW:0]    head_sum;
  assign committed = (((LP_CUT & 256) != 0) || ccount_fl <= count_fl) ? ccount_fl : count_fl;
  always_comb begin
    for (int k = 0; k < NRET; k++) begin
      if ((LP_CUT & 2) != 0) ret_ok[k] = ccount_q > CNTW'(k) && count_q > CNTW'(k) &&
                                  done_q_vec[head_q + SQW'(k)];
      else            ret_ok[k] = committed > CNTW'(k) && done_vec[head_q + SQW'(k)];
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
  assign head_d = head_sum[SQW-1:0];
  assign count_d = count_fl - n_ret;
  assign ccount_d = ccount_fl - n_ret;
  assign alive_w = ring_mask(head_q, count_q);
  // LP_CUT[9]: stores committed in this very cycle have no replay wait: the fill wake-up may use the registered count
  assign win4 = ((LP_CUT & 512) != 0)
                ? ring_mask(head_q, ccount_q > count_q ? count_q : ccount_q)
                : ring_mask(head_q, ccount_cm > count_q ? count_q : ccount_cm);
  // LP_CUT[13]: the drain only sees stores committed at the start of the cycle
  assign win13 = ring_mask(head_q, ((LP_CUT & 8192) != 0) ? (ccount_q > count_q ? count_q : ccount_q) : committed);
  // LP_CUT[12]: the same window without the count chain: alive at the start, not retired, not cut by the mispredict
  // (a cut removes every entry whose br_mask hits: younger entries carry the bit), not above the committed window
  // on a flush
  assign alive_post = ((LP_CUT & 4096) != 0)
                      ? (alive_w & ~ev_ret & ~(mispred ? hit_slot : '0) &
                         (flush ? ring_mask(head_q, ccount_cm) : '1))
                      : ring_mask(head_d, count_d);
  // LP_CUT[15]: the same without the count chain (entries allocated in this cycle are not looked up through this view)
  assign alive_fl = ((LP_CUT & 32768) != 0)
                    ? (alive_w & ~(mispred ? hit_slot : '0) & (flush ? ring_mask(head_q, ccount_cm) : '1))
                    : ring_mask(head_q, count_fl);

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
