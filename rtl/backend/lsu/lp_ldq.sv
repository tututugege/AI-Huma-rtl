// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LDQ of the staged LSU: event decode for the per-entry state machines)
`default_nettype none

// LDQ array of the staged LSU: one lp_ldq_ent per entry; the events of the glue (L2 decision, DCache response, AGU
// arrival, DTLB result, launch, wake-up) are decoded here into per-entry events.  Also: MMIO load pick, MSHR-FULL wake
// limit (first LD entries), vector views used by the write-back / replay logic.
module lp_ldq
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
  import memcpu_pkg::REPLAY_HIT;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [ROBW-1:0]     dec_rob_idx,
  input  logic                dec_rob_flag,
  // P2 MMIO response
  input  logic                mm_go,
  input  logic [LQW-1:0]      mm_idx,
  input  logic [XLEN_BITS-1:0]         mm_data,
  // P3 L2a/L2b decisions, DCache load responses
  input  lp_pl12_t            pl12 [NLD],
  input  lp_l2dec_t           l2a_dec [NLD],
  input  lp_pl2b_t            pl2b [NLD],
  input  lp_l2dec_t           l2b_dec [NLD],
  input  logic [NLD-1:0]      dcl_valid,
  input  logic [31:0]         dcl_req_id [NLD],
  input  logic [XLEN_BITS-1:0]         dcl_data [NLD],
  input  logic [1:0]          dcl_replay [NLD],
  input  logic [NLD-1:0]      rs_busy,
  // P5 write-back
  input  logic [LQ-1:0]       wb_go,
  input  logic [LQ-1:0]       wb_go_d,
  input  logic [NLD-1:0]      wbd_v,
  input  logic [LQW-1:0]      wbd_idx [NLD],
  input  logic [XLEN_BITS-1:0]         wbd_data [NLD],
  // memory speculation
  input  logic [SQW:0]        head_tag,
  input  logic [CNTW-1:0]     count_q,
  input  logic                unk_any,
  input  logic [SQW-1:0]      unk_rank,
  input  logic [NST-1:0]      sa_v,
  input  logic [SQW-1:0]      sa_rank [NST],
  input  logic [11:0]         sa_voff [NST],
  input  logic [2:0]          sa_f3 [NST],
  input  logic [NLD-1:0]      cam_en,
  input  logic [NLD-1:0]      cam_unk,
  output logic [LQ-1:0]       vio_new,
  // P6 / P8 / P12 L1
  input  lp_agu_ld_t          agl [NLD],
  input  lp_l1in_t            l1 [NLD],
  input  lp_tl_t              tl_l [NLD],
  input  logic [NLD-1:0]      l1_launch,
  // P9 MMIO issue
  input  logic                rb_hi_valid,
  input  logic [ROBW-1:0]     rb_hi_rob_idx,
  input  logic                rb_head_valid,
  input  logic [ROBW-1:0]     rb_head_rob_idx,
  input  logic [SQW:0]        stq_head_tag,
  input  logic                unc_busy,
  // P10
  input  lp_dis_ld_t          dis [NDIS],
  // P13 wake-up
  input  logic [SQ-1:0]       ev_sta,
  input  logic [SQ-1:0]       ev_data,
  input  logic [SQ-1:0]       ev_ret,
  input  logic [SQ-1:0]       ev_sc,
  input  logic [SQ-1:0]       alive_post,
  input  lp_sta_info_t        sta_info [NST],
  input  lp_std_t             sdw [NSD],
  input  logic                fill_v,
  input  logic [LINEW-1:0]    fill_line,
  // P14
  input  logic [LQ-1:0]       rp_pick,
  // views
  output lp_ldq_t             q_o [LQ],
  output logic [LQ-1:0]       empty_w,
  output logic [LQ-1:0]       l2_ok,
  output logic [LQ-1:0]       rs_ok,
  output logic [XLEN_BITS-1:0]         res_v [LQ],
  output logic [LQ-1:0]       pipe_st,
  output logic [LQ-1:0]       wb3_st,
  output logic [LQ-1:0]       wbp_st,
  output logic [LQ-1:0]       wbp_m,
  output logic [NLD-1:0]      ag_acc,
  output logic [LQ-1:0]       kill_cur,
  output logic [LQ-1:0]       rdy9,
  output logic                mi_v,
  output logic [LQW-1:0]      mi_idx,
  output logic [31:0]         mi_addr,
  output logic [2:0]          mi_func3
);

  logic [LQ-1:0] mmw_ok, mi_oh, full_cand, full_ok;
  logic [NLD-1:0] ag_acc_e [LQ];
  logic [LQ-1:0] full_oh [NLD];
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [LQW-1:0] full_ix [NLD];
  logic [NLD-1:0] full_pv;
  /* verilator lint_on UNUSEDSIGNAL */

  ttg_first_set #(.N(LQ)) u_mi (.req(mmw_ok), .onehot(mi_oh), .any(mi_v));
  ttg_onehot_to_idx #(.N(LQ)) u_mix (.onehot(mi_oh), .idx(mi_idx));
  assign mi_addr = q_o[mi_idx].paddr;
  assign mi_func3 = q_o[mi_idx].func3;

  // MSHR-FULL wake: the first LD entries (lowest index) of the full candidates
  lp_pickn #(.N(LQ), .K(NLD)) u_full (.vec(full_cand), .onehot(full_oh), .idx(full_ix), .v(full_pv));
  always_comb begin
    full_ok = '0;
    for (int m = 0; m < NLD; m++) full_ok = full_ok | full_oh[m];
  end

  always_comb begin
    ag_acc = '0;
    for (int e = 0; e < LQ; e++) ag_acc = ag_acc | ag_acc_e[e];
  end

  // Wake-up of the STLF load that parks at L2b in this cycle (purely registered pl2b -> zero CAM on lp_wk)
  lp_wk_t l2w [NLD];
  for (genvar p = 0; p < NLD; p++) begin : g_l2w
    lp_wk u_wk (.cause(3'(l2b_dec[p].cause)), .blk(pl2b[p].cand), .wt(l2b_dec[p].wait_c[OW-1:0]),
                .l_voff(pl2b[p].voff), .l_paddr(pl2b[p].paddr), .l_func3(pl2b[p].func3), .ev_sta(ev_sta),
                .ev_data(ev_data), .ev_ret(ev_ret), .ev_sc(ev_sc), .alive_post(alive_post),
                .sta_info(sta_info), .sdw(sdw), .o(l2w[p]));
  end

  for (genvar e = 0; e < LQ; e++) begin : g_e
    logic            l2_v, rs_v, rs_hit_e, rs_busy_e;
    logic [EPW-1:0]  l2_ep, rs_ep;
    lp_l2dec_t       l2_dec_e;
    logic [1:0]      rs_rep_e;
    logic [XLEN_BITS-1:0]     rs_raw_e;
    logic [NLD-1:0]  tl_tgt, l1_tgt;
    lp_wk_t          l2w_e;
    logic            sp_we, sp_val;
    logic [XLEN_BITS-1:0]     wb_d_data;

    always_comb begin
      l2_v = 1'b0;
      l2_ep = '0;
      l2_dec_e = '0;
      rs_v = 1'b0;
      rs_ep = '0;
      rs_hit_e = 1'b0;
      rs_busy_e = 1'b0;
      rs_rep_e = '0;
      rs_raw_e = '0;
      l2w_e = '0;
      sp_we = 1'b0;
      sp_val = 1'b0;
      wb_d_data = '0;
      for (int p = 0; p < NLD; p++) begin
        tl_tgt[p] = l1[p].v && l1[p].need_tlb && l1[p].ldq == LQW'(e);
        l1_tgt[p] = l1[p].v && l1[p].ldq == LQW'(e);
        if (wbd_v[p] && wbd_idx[p] == LQW'(e)) wb_d_data = wbd_data[p];
        if (pl12[p].v && pl12[p].ldq == LQW'(e) && pl12[p].epoch == q_o[e].epoch) begin
          l2_v = 1'b1;
          l2_ep = pl12[p].epoch;
          l2_dec_e = l2a_dec[p];
          if (cam_en[p]) begin
            sp_we = 1'b1;
            sp_val = cam_unk[p];
          end
        end
        if (pl2b[p].v && pl2b[p].ldq == LQW'(e) && pl2b[p].epoch == q_o[e].epoch) begin
          l2_v = 1'b1;
          l2_ep = pl2b[p].epoch;
          l2_dec_e = l2b_dec[p];
          l2w_e = l2w[p];
        end
        // (the epoch is part of the match: a stale response of an earlier request of this entry on another port must not
        // shadow the response of the current request; the last matching port wins only among live responses)
        if (dcl_valid[p] && !dcl_req_id[p][31] && dcl_req_id[p][LQW-1:0] == LQW'(e) &&
            dcl_req_id[p][LQW +: EPW] == q_o[e].epoch) begin
          rs_v = 1'b1;
          rs_ep = dcl_req_id[p][LQW +: EPW];
          rs_hit_e = dcl_replay[p] == REPLAY_HIT;
          rs_rep_e = dcl_replay[p];
          rs_raw_e = dcl_data[p];
          rs_busy_e = rs_busy[p];
        end
      end
    end

    lp_ldq_ent #(.IDX(e)) u_ent (
      .clk(clk), .rst_n(rst_n), .flush(flush), .mispred(mispred), .dec_rob_idx(dec_rob_idx), .dec_rob_flag(dec_rob_flag),
      .mm_go(mm_go && mm_idx == LQW'(e)), .mm_data(mm_data),
      .l2_v(l2_v), .l2_ep(l2_ep), .l2_dec(l2_dec_e), .l2_ok(l2_ok[e]),
      .rs_v(rs_v), .rs_ep(rs_ep), .rs_hit(rs_hit_e), .rs_rep(rs_rep_e), .rs_raw(rs_raw_e), .rs_busy(rs_busy_e),
      .rs_ok(rs_ok[e]),
      .wb_go(wb_go[e]), .wb_go_d(wb_go_d[e]), .wb_d_data(wb_d_data), .pipe_st(pipe_st[e]),
      .wb3_st(wb3_st[e]), .wbp_st(wbp_st[e]),
      .wbp_m(wbp_m[e]), .res_v(res_v[e]),
      .head_tag(head_tag), .count_q(count_q), .unk_any(unk_any), .unk_rank(unk_rank), .sa_v(sa_v),
      .sa_rank(sa_rank), .sa_voff(sa_voff), .sa_f3(sa_f3), .sp_we(sp_we), .sp_val(sp_val), .vio_new(vio_new[e]),
      .ag(agl), .ag_acc(ag_acc_e[e]),
      .tl_tgt(tl_tgt), .tl(tl_l),
      .rb_hi_valid(rb_hi_valid), .rb_hi_rob_idx(rb_hi_rob_idx), .rb_head_valid(rb_head_valid),
      .rb_head_rob_idx(rb_head_rob_idx), .stq_head_tag(stq_head_tag), .unc_busy(unc_busy),
      .mmw_ok(mmw_ok[e]), .mi_pick(mi_oh[e]),
      .dis(dis),
      .l1_tgt(l1_tgt), .l1_launch(l1_launch), .kill_cur(kill_cur[e]),
      .ev_sta(ev_sta), .ev_data(ev_data), .ev_ret(ev_ret), .ev_sc(ev_sc), .alive_post(alive_post),
      .sta_info(sta_info), .sdw(sdw), .fill_v(fill_v), .fill_line(fill_line), .l2w(l2w_e), .full_ok(full_ok[e]),
      .full_cand(full_cand[e]), .rdy9(rdy9[e]), .rp_pick(rp_pick[e]),
      .q_o(q_o[e]), .empty_w(empty_w[e]));
  end

endmodule

`default_nettype wire
