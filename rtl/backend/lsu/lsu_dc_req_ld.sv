// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2dcache_ldq: wait_dcache window -> up to NLD DCache load requests)
`default_nettype none

// M: the first NLD ReadyToIssue loads of the wait_dcache window whose replay wait has run out issue a DCache request.
// The scan stops as soon as NLD requests are out; a candidate that is still counting down (wait > 1) only
// decrements, a candidate whose countdown ends (wait <= 1) issues in the same cycle.
module lsu_dc_req_ld
  import lsu_pkg::*;
(
  input  lsu_ring_t        wdc_i,                      // wait_dcache queue after this cycle's appends / kills
  input  logic [RWW-1:0]   wd_wait   [RN],             // replay wait after response and wake-up
  input  logic [GENW-1:0]  req_gen_q,                  // cur.req_gen
  input  ld_state_t        ld_st_fl  [LQ],
  input  ldq_fld_t         ld_fld    [LQ],
  output logic [NLD-1:0]   req_valid,
  // re-issue of a load that got a non-HIT response before (EXP-009 training filter)
  output logic [NLD-1:0]   req_replay,
  output logic [31:0]      req_addr  [NLD],
  output logic [RIW+GENW-1:0] req_id [NLD],            // {generation, wait_dcache slot}
  output logic [LQ-1:0]    iss_go,
  output logic [RN-1:0]    wd_dec,
  output logic [RN-1:0]    gen_we,
  output logic [GENW-1:0]  gen_wd    [RN],
  output logic [RCW-1:0]   n_iss_total
);
  logic [WIN-1:0] valid_w, cand, issue, dec;
  logic [RIW-1:0] idx_w [WIN], slot_w [WIN];
  logic [RWW-1:0] w_p [WIN];
  logic [RCW-1:0] n_iss [WIN+1];                      // requests issued before position p

  lsu_ring_win u_win (.ring(wdc_i), .valid_w(valid_w), .idx_w(idx_w));
  always_comb begin
    n_iss[0] = '0;
    for (int p = 0; p < WIN; p++) begin
      slot_w[p] = wdc_i.head + RIW'(p);
      w_p[p]    = wd_wait[slot_w[p]];
      cand[p]   = valid_w[p] && ld_st_fl[idx_w[p]] == LD_READY_TO_ISSUE;
      issue[p]  = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] < RWW'(2);
      dec[p]    = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] != '0;
      n_iss[p+1] = n_iss[p] + RCW'(issue[p]);
    end
  end
  assign n_iss_total = n_iss[WIN];

  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      req_valid[k] = 1'b0;
      req_addr[k]  = '0;
      req_id[k]    = '0;
      req_replay[k] = 1'b0;
      for (int p = 0; p < WIN; p++) begin
        if (issue[p] && n_iss[p] == RCW'(k)) begin
          req_valid[k] = 1'b1;
          req_addr[k]  = ld_fld[idx_w[p]].paddr;
          req_id[k]    = {req_gen_q + GENW'(k), slot_w[p]};
          req_replay[k] = ld_fld[idx_w[p]].replay != 2'd0;
        end
      end
    end
  end
  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [WIN-1:0] by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p] = issue[p] && idx_w[p] == RIW'(e);
    end
    assign iss_go[e] = |by_pos;
  end
  for (genvar s = 0; s < RN; s++) begin : g_slot
    logic [WIN-1:0] by_iss, by_dec;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_iss[p] = issue[p] && slot_w[p] == RIW'(s);
      assign by_dec[p] = dec[p]   && slot_w[p] == RIW'(s);
    end
    always_comb begin
      gen_we[s] = |by_iss;
      wd_dec[s] = |by_dec;
      gen_wd[s] = '0;
      for (int p = 0; p < WIN; p++) if (by_iss[p]) gen_wd[s] = req_gen_q + GENW'(n_iss[p]);
    end
  end

endmodule

`default_nettype wire
