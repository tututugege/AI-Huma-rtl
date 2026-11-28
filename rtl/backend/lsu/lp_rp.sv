// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (replay registers: comb_tlb_out_p consume, comb_flush_p clear, comb_che
`default_nettype none

// Replay registers of the staged LSU: RP[r] holds a load that re-enters L1 (consumed when a slot is free, cleared
// when its
// entry died, filled from the RDY vector by a find-first rotated by a round-robin pointer; this includes entries
// woken in
// the same cycle), and the STA replay register (round-robin over the stores with a pending DTLB retry).
module lp_rp
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic [LQ-1:0]       rdy9,
  input  logic [LQ-1:0]       empty8,
  input  logic [NRP-1:0]      rp_cons,
  input  logic                srp_cons,
  input  logic [SQ-1:0]       trp_v,
  input  logic [SQ-1:0]       alive_post,
  input  logic [SQ-1:0]       alive_fl,
  input  lp_ldq_t             ldq_q [LQ],
  output logic [NRP-1:0]      rp_v_q,
  output logic [LQW-1:0]      rp_ldq_q [NRP],
  output lp_rp_ent_t          rp_f_q [NRP],
  output logic [LQ-1:0]       rp_pick,
  output logic                srp_v_q,
  output logic [SQW-1:0]      srp_stq_q,
  output logic [SQ-1:0]       srp_take
);

  logic [LQW-1:0]  rp_ptr_q;
  logic [LQ-1:0]   rp_ge_q;
  logic [NRP-1:0]  rp_v_c, rp_take;
  logic [LQ-1:0]   rdy_hi, rdy_lo, hi_oh [NRP], lo_oh [NRP], rp_oh_unrot [NRP], rp_selo [NRP];
  logic [LQW-1:0]  hi_ix [NRP], lo_ix [NRP], rp_ix [NRP], rp_new [NRP];
  logic [NRP-1:0]  hi_v, lo_v, rp_pv;
  logic [2:0]      hi_cnt;
  logic [LQW-1:0]  rp_ptr_d;
  lp_rp_ent_t      ldq_rp_v [LQ], rp_cand_f [NRP], rp_new_f [NRP];

  // Parallel hi/lo split on registered rp_ge_q (eliminates both 64-bit rotr64 and rotl64 barrel shifters)
  assign rdy_hi = rdy9 & rp_ge_q;
  assign rdy_lo = rdy9 & ~rp_ge_q;
  lp_pickn #(.N(LQ), .K(NRP)) u_rp_hi (.vec(rdy_hi), .onehot(hi_oh), .idx(hi_ix), .v(hi_v));
  lp_pickn #(.N(LQ), .K(NRP)) u_rp_lo (.vec(rdy_lo), .onehot(lo_oh), .idx(lo_ix), .v(lo_v));

  always_comb begin
    hi_cnt = '0;
    for (int j = 0; j < NRP; j++) hi_cnt = hi_cnt + 3'(hi_v[j]);
    for (int j = 0; j < NRP; j++) begin
      logic [1:0] lo_k;
      lo_k = 2'(3'(j) - hi_cnt);
      if (hi_v[j]) begin
        rp_pv[j]       = 1'b1;
        rp_ix[j]       = hi_ix[j];
        rp_oh_unrot[j] = hi_oh[j];
      end else begin
        rp_pv[j]       = lo_v[lo_k];
        rp_ix[j]       = lo_ix[lo_k];
        rp_oh_unrot[j] = lo_oh[lo_k];
      end
    end
  end

  // Select each candidate's immutable payload directly via one-hot mux (in parallel with nfb[r], no 64:1 binary mux!)
  always_comb begin
    for (int e = 0; e < LQ; e++) begin
      ldq_rp_v[e].vaddr     = ldq_q[e].vaddr;
      ldq_rp_v[e].func3     = ldq_q[e].func3;
      ldq_rp_v[e].snap_idx  = ldq_q[e].snap_idx;
      ldq_rp_v[e].snap_flag = ldq_q[e].snap_flag;
      ldq_rp_v[e].pa_v      = ldq_q[e].pa_v;
      ldq_rp_v[e].paddr     = ldq_q[e].paddr;
      ldq_rp_v[e].mmio      = ldq_q[e].mmio;
      ldq_rp_v[e].lrsc      = ldq_q[e].lrsc;
      ldq_rp_v[e].epoch     = ldq_q[e].epoch;
      ldq_rp_v[e].second    = ldq_q[e].second;
      ldq_rp_v[e].wait_b    = ldq_q[e].wait_b;
      ldq_rp_v[e].dest_preg  = ldq_q[e].dest_preg;
      ldq_rp_v[e].rob_idx    = ldq_q[e].rob_idx;
      ldq_rp_v[e].rob_flag   = ldq_q[e].rob_flag;
      ldq_rp_v[e].no_l1_spec = ldq_q[e].no_l1_spec;
    end
  end
  for (genvar j = 0; j < NRP; j++) begin : g_rpf
    ttg_onehot_mux #(.N(LQ), .W($bits(lp_rp_ent_t))) u_mux (
      .sel(rp_oh_unrot[j]), .data(ldq_rp_v), .out(rp_cand_f[j])
    );
  end

  // the j-th free register takes the j-th RDY entry (in rotated order); busy registers keep theirs
  logic [2:0] nfb [NRP];  // free registers before r
  always_comb begin
    rp_pick = '0;
    rp_ptr_d = rp_ptr_q;
    for (int r = 0; r < NRP; r++) begin
      rp_v_c[r] = rp_v_q[r] && !rp_cons[r] && !empty8[rp_ldq_q[r]];
      nfb[r] = '0;
      for (int k = 0; k < r; k++) nfb[r] = nfb[r] + 3'(!rp_v_c[k]);
      rp_take[r] = 1'b0;
      rp_new[r] = '0;
      rp_new_f[r] = '0;
      rp_selo[r] = '0;
      for (int j = 0; j < NRP; j++) begin
        if (nfb[r] == 3'(j)) begin
          rp_take[r]  = !rp_v_c[r] && rp_pv[j];
          rp_new[r]   = rp_ix[j];
          rp_new_f[r] = rp_cand_f[j];
          rp_selo[r]  = rp_oh_unrot[j];
        end
      end
    end
    for (int r = 0; r < NRP; r++) begin
      if (rp_take[r]) rp_pick = rp_pick | rp_selo[r];
      if (rp_take[r]) rp_ptr_d = rp_new[r] + LQW'(1);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rp_v_q   <= '0;
      rp_ptr_q <= '0;
      rp_ge_q  <= '1;
    end else begin
      rp_v_q   <= rp_v_c | rp_take;
      rp_ptr_q <= rp_ptr_d;
      rp_ge_q  <= LQ'(64'(-1) << rp_ptr_d);
    end
    for (int r = 0; r < NRP; r++) begin
      if (rp_take[r]) begin
        rp_ldq_q[r] <= rp_new[r];
        rp_f_q[r]   <= rp_new_f[r];
      end
    end
  end

  // STA replay register: store with a pending DTLB retry (after retire), taken when the register is free.  The pick
  // rotates over the STQ index (srp_ptr, like rp_ptr for the loads): the DTLB walk is shared between pages, and always
  // taking the oldest store starves a younger walk owner (Linux boot, ROB deadlock).
  // first set bit at or after srp_ptr, else the first set bit overall (no rotation of the late request vector)
  logic [SQ-1:0] trp_vec, trp_hi, trp_oh_hi, trp_oh_lo, trp_oh, trp_ge_q;
  logic [SQW-1:0] trp_ix, srp_new, srp_ptr_q, srp_ptr_d;
  logic trp_any, trp_any_hi, trp_any_lo, srp_v_c, srp_take_any;
  always_comb begin
    srp_v_c = srp_v_q && !srp_cons && alive_fl[srp_stq_q];
    trp_vec = trp_v & alive_post;
    trp_hi  = trp_vec & trp_ge_q;
    trp_any = trp_any_hi || trp_any_lo;
    trp_oh  = trp_any_hi ? trp_oh_hi : trp_oh_lo;
    srp_new = trp_ix;
    srp_take_any = !srp_v_c && trp_any;
    srp_ptr_d = srp_take_any ? (srp_new + SQW'(1)) : srp_ptr_q;
  end
  lp_ffs #(.N(SQ)) u_trp_hi (.req(trp_hi),  .onehot(trp_oh_hi), .any(trp_any_hi));
  lp_ffs #(.N(SQ)) u_trp_lo (.req(trp_vec), .onehot(trp_oh_lo), .any(trp_any_lo));
  ttg_onehot_to_idx #(.N(SQ)) u_trpi (.onehot(trp_oh), .idx(trp_ix));
  assign srp_take = srp_take_any ? trp_oh : '0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srp_v_q   <= 1'b0;
      srp_ptr_q <= '0;
      trp_ge_q  <= '1;
    end else begin
      srp_v_q   <= srp_v_c || trp_any;
      srp_ptr_q <= srp_ptr_d;
      trp_ge_q  <= SQ'(64'(-1) << srp_ptr_d);
    end
    if (srp_take_any) srp_stq_q <= srp_new;
  end

endmodule

`default_nettype wire
