// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (STQ of the staged LSU: event decode for the per-entry state machines)
`default_nettype none

// STQ array of the staged LSU: one lp_stq_ent per entry; decodes the port events (DCache store response, STA slots,
// dispatch allocation) into per-entry events and exports the vector views used by the glue.
module lp_stq
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                rb_flush,
  input  logic [BRW-1:0]      clear_mask,
  input  logic [SQW-1:0]      head_q,
  input  logic [SQ-1:0]       alive_w,
  input  logic [SQ-1:0]       win4,
  input  logic [SQ-1:0]       win13,
  input  logic [SQ-1:0]       cm_go,
  // P2
  input  logic                mm_done,
  input  logic [SQW-1:0]      mm_idx,
  // P4
  input  logic [NST-1:0]      dcs_valid,
  input  logic [31:0]         dcs_req_id [NST],
  input  logic [1:0]          dcs_replay [NST],
  input  logic                fill_v,
  input  logic [LINEW-1:0]    fill_line,
  // P5
  input  logic [SQ-1:0]       wb_go_s,
  input  logic [SQ-1:0]       sc_go,
  input  logic                rsv_valid,
  input  logic [31:0]         rsv_addr,
  // P6 / P8
  input  lp_std_t             sdw [NSD],
  input  lp_agu_st_t          ags [NST],
  input  logic [NST-1:0]      s1_v,
  input  logic [SQW-1:0]      s1_stq [NST],
  input  logic [NST-1:0]      tl_s_miss,
  input  lp_tl_t              tl_s [NST],
  // P10
  input  logic [SQ-1:0]       al_v,
  input  logic [SQ-1:0][NDIS-1:0] al_slot,
  input  lp_dis_st_t          dis_st [NDIS],
  // P13 / P14
  input  logic [SQ-1:0]       dr_pick,
  input  logic [SQ-1:0]       dr_fol,
  input  logic [SQ-1:0]       wb_mark,
  input  logic [SQW-1:0]      dr_ml [SQ],
  input  logic [SQ-1:0]       dr_mmio,
  input  logic [SQ-1:0]       srp_take,
  // views
  output lp_stq_t             sq [SQ],
  output logic [SQ-1:0]       cv_va,
  output logic [11:0]         cv_voff [SQ],
  output logic [2:0]          cv_f3 [SQ],
  output lp_sta_info_t        vw [SQ],
  output logic [SQ-1:0]       done_v,
  output logic [SQ-1:0]       trp_v,
  output logic [SQ-1:0]       d_elig,
  output logic [SQ-1:0]       d_rdy,
  output logic [SQ-1:0]       wbi_v,              // handled by the write-buffer insertion
  output logic [SQ-1:0]       sd_acc,
  output logic [NST-1:0]      sa_acc
);

  logic [SQ-1:0] full_cand, full_ok;
  logic [SQ-1:0] full_oh [NST];
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [SQW-1:0] full_ix [NST];
  logic [NST-1:0] full_pv;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [SQ-1:0] fc_rot, fok_rot;
  logic [NST-1:0] sa_acc_e [SQ];

  assign fc_rot = SQ'(rotr64(64'(full_cand), head_q));
  lp_pickn #(.N(SQ), .K(NST)) u_full (.vec(fc_rot), .onehot(full_oh), .idx(full_ix), .v(full_pv));
  always_comb begin
    fok_rot = '0;
    for (int m = 0; m < NST; m++) fok_rot = fok_rot | full_oh[m];
    full_ok = SQ'(rotl64(64'(fok_rot), head_q));
    sa_acc = '0;
    for (int j = 0; j < SQ; j++) sa_acc = sa_acc | sa_acc_e[j];
  end

  for (genvar j = 0; j < SQ; j++) begin : g_e
    logic          rsp_v;
    logic [1:0]    rsp_rep;
    logic          mf_q;               // sent as the follower of the store ml_q (shares its port and response)
    logic [SQW-1:0] ml_q;
    logic [NST-1:0] tl_tgt;
    lp_dis_st_t    al_d;

    always_comb begin
      rsp_v = 1'b0;
      rsp_rep = '0;
      for (int k = 0; k < NST; k++) begin
        tl_tgt[k] = s1_v[k] && s1_stq[k] == SQW'(j);
        if (dcs_valid[k] && (dcs_req_id[k] == 32'(j) || (mf_q && dcs_req_id[k] == 32'(ml_q)))) begin
          rsp_v = 1'b1;
          rsp_rep = dcs_replay[k];
        end
      end
      al_d = '0;
      for (int i = 0; i < NDIS; i++) if (al_slot[j][i]) al_d = dis_st[i];
    end

    logic wbi_q;                       // handled by the write-buffer insertion
    assign wbi_v[j] = wbi_q;
    always_ff @(posedge clk) begin
      if (!rst_n || al_v[j]) wbi_q <= 1'b0;
      else if (wb_mark[j]) wbi_q <= 1'b1;
      if (!rst_n) mf_q <= 1'b0;
      else if (dr_pick[j]) mf_q <= dr_fol[j];
      if (dr_pick[j]) ml_q <= dr_ml[j];
    end

    lp_stq_ent #(.IDX(j)) u_ent (
      .clk(clk), .rst_n(rst_n), .rb_flush(rb_flush), .clear_mask(clear_mask), .alive_w(alive_w[j]),
      .cm_go(cm_go[j]), .mm_done(mm_done && mm_idx == SQW'(j)),
      .rsp_v(rsp_v), .rsp_rep(rsp_rep), .win4(win4[j]), .fill_v(fill_v), .fill_line(fill_line),
      .full_ok(full_ok[j]), .full_cand(full_cand[j]),
      .wb_go(wb_go_s[j]), .sc_go(sc_go[j]), .rsv_valid(rsv_valid), .rsv_addr(rsv_addr),
      .sdw(sdw), .sta(ags), .sd_acc(sd_acc[j]), .sa_acc(sa_acc_e[j]),
      .tl_tgt(tl_tgt), .tl_miss(tl_s_miss), .tl(tl_s),
      .al_v(al_v[j]), .al_d(al_d),
      .win13(win13[j]), .dr_pick(dr_pick[j]), .dr_mmio(dr_mmio[j]),
      .d_elig(d_elig[j]), .d_rdy(d_rdy[j]),
      .srp_take(srp_take[j]),
      .q_o(sq[j]), .cv_va(cv_va[j]), .cv_voff(cv_voff[j]), .cv_f3(cv_f3[j]), .vw(vw[j]),
      .done_v(done_v[j]), .trp_v(trp_v[j]));
  end

endmodule

`default_nettype wire
