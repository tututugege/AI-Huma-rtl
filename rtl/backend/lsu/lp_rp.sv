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
  output logic [NRP-1:0]      rp_v_q,
  output logic [LQW-1:0]      rp_ldq_q [NRP],
  output logic [LQ-1:0]       rp_pick,
  output logic                srp_v_q,
  output logic [SQW-1:0]      srp_stq_q,
  output logic [SQ-1:0]       srp_take
);

  logic [LQW-1:0]  rp_ptr_q;
  logic [NRP-1:0]  rp_v_c, rp_take;
  logic [LQ-1:0]   rdy_rot, rp_oh [NRP], rp_selo [NRP];
  logic [LQW-1:0]  rp_ix [NRP], rp_new [NRP];
  logic [NRP-1:0]  rp_pv;
  logic [LQW-1:0]  rp_ptr_d;
  assign rdy_rot = LQ'(rotr64(64'(rdy9), rp_ptr_q));
  lp_pickn #(.N(LQ), .K(NRP)) u_rp (.vec(rdy_rot), .onehot(rp_oh), .idx(rp_ix), .v(rp_pv));

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
      rp_selo[r] = '0;
      for (int j = 0; j < NRP; j++) begin
        if (nfb[r] == 3'(j)) begin
          rp_take[r] = !rp_v_c[r] && rp_pv[j];
          rp_new[r] = rp_ix[j] + rp_ptr_q;
          rp_selo[r] = rp_oh[j];
        end
      end
    end
    for (int r = 0; r < NRP; r++) begin
      if (rp_take[r]) rp_pick = rp_pick | rotl64(64'(rp_selo[r]), rp_ptr_q);
      if (rp_take[r]) rp_ptr_d = rp_new[r] + LQW'(1);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rp_v_q <= '0;
      rp_ptr_q <= '0;
    end else begin
      rp_v_q <= rp_v_c | rp_take;
      rp_ptr_q <= rp_ptr_d;
    end
    for (int r = 0; r < NRP; r++) if (rp_take[r]) rp_ldq_q[r] <= rp_new[r];
  end

  // STA replay register: store with a pending DTLB retry (after retire), taken when the register is free.  The pick
  // rotates over the STQ index (srp_ptr, like rp_ptr for the loads): the DTLB walk is shared between pages, and always
  // taking the oldest store starves a younger walk owner (Linux boot, ROB deadlock).
  logic [SQ-1:0] trp_vec, trp_rot, trp_oh;
  logic [SQW-1:0] trp_ix, srp_new, srp_ptr_q;
  logic trp_any, srp_v_c, srp_take_any;
  always_comb begin
    srp_v_c = srp_v_q && !srp_cons && alive_fl[srp_stq_q];
    trp_vec = trp_v & alive_post;
    trp_rot = SQ'(rotr64(64'(trp_vec), srp_ptr_q));
    srp_new = trp_ix + srp_ptr_q;
    srp_take_any = !srp_v_c && trp_any;
  end
  lp_ffs #(.N(SQ)) u_trp (.req(trp_rot), .onehot(trp_oh), .any(trp_any));
  ttg_onehot_to_idx #(.N(SQ)) u_trpi (.onehot(trp_oh), .idx(trp_ix));
  assign srp_take = srp_take_any ? SQ'(rotl64(64'(trp_oh), srp_ptr_q)) : '0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srp_v_q <= 1'b0;
      srp_ptr_q <= '0;
    end else begin
      srp_v_q <= srp_v_c || trp_any;
      if (srp_take_any) srp_ptr_q <= srp_new + SQW'(1);
    end
    if (srp_take_any) srp_stq_q <= srp_new;
  end

endmodule

`default_nettype wire
