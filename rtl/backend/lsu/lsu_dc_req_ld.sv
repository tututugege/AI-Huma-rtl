// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2dcache_ldq: wait_dcache window -> up to NLD DCache load requests)
`default_nettype none

module lsu_dc_req_ld
  import lsu_pkg::*;
(
  input  lsu_ring_t        wdc_i,
  input  logic [GENW-1:0]  wd_gen_i  [RN],
  input  logic [RWW-1:0]   wd_wait_i [RN],
  input  logic [GENW-1:0]  req_gen_q,                 // cur.req_gen
  input  ld_state_t        ld_st_i   [LQ],
  input  logic [31:0]      ld_paddr  [LQ],
  output logic [NLD-1:0]   req_valid,
  output logic [31:0]      req_addr  [NLD],
  output logic [RIW+GENW-1:0] req_id [NLD],           // {generation, wait_dcache slot}
  output ld_state_t        ld_st_o   [LQ],
  output logic [GENW-1:0]  wd_gen_o  [RN],
  output logic [RWW-1:0]   wd_wait_o [RN],
  output logic [GENW-1:0]  req_gen_o
);

  logic [WIN-1:0] valid_w, cand, issue, dec;
  logic [RIW-1:0] idx_w [WIN], slot_w [WIN];
  logic [RWW-1:0] w_p [WIN];
  logic [RCW-1:0] n_iss [WIN+1];                      // requests issued before position p

  lsu_ring_win u_win (.ring(wdc_i), .valid_w(valid_w), .idx_w(idx_w));

  // The scan stops as soon as NLD requests are out; a candidate that is still counting down (wait > 1) only
  // decrements, a candidate whose countdown ends (wait <= 1) issues in the same cycle.
  always_comb begin
    n_iss[0] = '0;
    for (int p = 0; p < WIN; p++) begin
      slot_w[p] = wdc_i.head + RIW'(p);
      w_p[p]    = wd_wait_i[slot_w[p]];
      cand[p]   = valid_w[p] && ld_st_i[idx_w[p]] == LD_READY_TO_ISSUE;
      issue[p]  = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] < RWW'(2);
      dec[p]    = cand[p] && n_iss[p] < RCW'(NLD) && w_p[p] != '0;
      n_iss[p+1] = n_iss[p] + RCW'(issue[p]);
    end
  end

  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      req_valid[k] = 1'b0;
      req_addr[k]  = '0;
      req_id[k]    = '0;
      for (int p = 0; p < WIN; p++) begin
        if (issue[p] && n_iss[p] == RCW'(k)) begin
          req_valid[k] = 1'b1;
          req_addr[k]  = ld_paddr[idx_w[p]];
          req_id[k]    = {req_gen_q + GENW'(k), slot_w[p]};
        end
      end
    end
    req_gen_o = req_gen_q + GENW'(n_iss[WIN]);
  end

  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [WIN-1:0] by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p] = issue[p] && idx_w[p] == RIW'(e);
    end
    assign ld_st_o[e] = (|by_pos) ? LD_WAIT_DCACHE_RESP : ld_st_i[e];
  end
  for (genvar s = 0; s < RN; s++) begin : g_slot
    logic [WIN-1:0] by_iss, by_dec;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_iss[p] = issue[p] && slot_w[p] == RIW'(s);
      assign by_dec[p] = dec[p]   && slot_w[p] == RIW'(s);
    end
    always_comb begin
      wd_wait_o[s] = (|by_dec) ? wd_wait_i[s] - RWW'(1) : wd_wait_i[s];
      wd_gen_o[s]  = wd_gen_i[s];
      for (int p = 0; p < WIN; p++) if (by_iss[p]) wd_gen_o[s] = req_gen_q + GENW'(n_iss[p]);
    end
  end

endmodule

`default_nettype wire
