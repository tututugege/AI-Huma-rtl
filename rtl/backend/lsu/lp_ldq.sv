// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LDQ of the staged LSU: event decode for the per-entry state machines)
`default_nettype none

// LDQ array of the staged LSU: one lp_ldq_ent per entry; the events of the glue (L2 decision, DCache response, AGU
// arrival, DTLB result, launch, wake-up) are decoded here into per-entry events.  Also: MMIO load pick, MSHR-FULL wake
// limit (first LD entries), vector views used by the write-back / replay logic.
module lp_ldq
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [BRW-1:0]      dec_br_mask,
  input  logic [BRW-1:0]      clear_mask,
  // P2 MMIO response
  input  logic                mm_go,
  input  logic [LQW-1:0]      mm_idx,
  input  logic [31:0]         mm_data,
  // P3 L2 decisions of the L1/L2 registers, DCache load responses
  input  lp_pl12_t            pl12 [NLD],
  input  lp_l2dec_t           l2_dec [NLD],
  input  logic [NLD-1:0]      dcl_valid,
  input  logic [31:0]         dcl_req_id [NLD],
  input  logic [31:0]         dcl_data [NLD],
  input  logic [1:0]          dcl_replay [NLD],
  input  logic [NLD-1:0]      rs_busy,
  // P5 write-back
  input  logic [LQ-1:0]       wb_go,
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
  output logic [31:0]         res_v [LQ],
  output logic [LQ-1:0]       wbp3,
  output logic [LQ-1:0]       pipe_r,
  output logic [LQ-1:0]       wb3_r,
  output logic [LQ-1:0]       wbp_r,
  output logic [LQ-1:0]       wbp_m,
  output logic [NLD-1:0]      ag_acc,
  output logic [LQ-1:0]       pipe5,
  output logic [LQ-1:0]       pipe8,
  output logic [LQ-1:0]       dead_r,
  output logic [LQ-1:0]       empty8,
  output logic [EPW-1:0]      epoch_nx [LQ],
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

  lp_ffs #(.N(LQ)) u_mi (.req(mmw_ok), .onehot(mi_oh), .any(mi_v));
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

  // LP_L2[8]: wake-up of the load that parks at L2 in this cycle, evaluated per port (park information from the L1/L2
  // register and the L2 decision) instead of per entry behind the L2 decision
  lp_wk_t l2w [NLD];
  for (genvar p = 0; p < NLD; p++) begin : g_l2w
    if ((LP_L2 & 256) != 0) begin : g_on
      lp_wk u_wk (.cause(3'(l2_dec[p].cause)), .blk(pl12[p].cand), .wt(l2_dec[p].wait_c[1:0]),
                  .l_voff(pl12[p].voff), .l_paddr(pl12[p].paddr), .l_func3(pl12[p].func3), .ev_sta(ev_sta),
                  .ev_data(ev_data), .ev_ret(ev_ret), .ev_sc(ev_sc), .alive_post(alive_post),
                  .sta_info(sta_info), .sdw(sdw), .o(l2w[p]));
    end else begin : g_off
      assign l2w[p] = '0;
    end
  end

  for (genvar e = 0; e < LQ; e++) begin : g_e
    logic            l2_v, rs_v, rs_hit_e, rs_busy_e;
    logic [EPW-1:0]  l2_ep, rs_ep;
    lp_l2dec_t       l2_dec_e;
    logic [1:0]      rs_rep_e;
    logic [31:0]     rs_raw_e;
    logic [NLD-1:0]  tl_tgt, l1_tgt;
    lp_wk_t          l2w_e;

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
      for (int p = 0; p < NLD; p++) begin
        tl_tgt[p] = l1[p].v && l1[p].need_tlb && l1[p].ldq == LQW'(e);
        l1_tgt[p] = l1[p].v && l1[p].ldq == LQW'(e);
        if (pl12[p].v && pl12[p].ldq == LQW'(e)) begin
          l2_v = 1'b1;
          l2_ep = pl12[p].epoch;
          l2_dec_e = l2_dec[p];
          l2w_e = l2w[p];
        end
        if (dcl_valid[p] && !dcl_req_id[p][31] && dcl_req_id[p][LQW-1:0] == LQW'(e)) begin
          rs_v = 1'b1;
          rs_ep = dcl_req_id[p][LQW +: EPW];
          rs_hit_e = dcl_replay[p] == RT_HIT;
          rs_rep_e = dcl_replay[p];
          rs_raw_e = dcl_data[p];
          rs_busy_e = rs_busy[p];
        end
      end
    end

    lp_ldq_ent #(.IDX(e)) u_ent (
      .clk(clk), .rst_n(rst_n), .flush(flush), .mispred(mispred), .dec_br_mask(dec_br_mask), .clear_mask(clear_mask),
      .mm_go(mm_go && mm_idx == LQW'(e)), .mm_data(mm_data),
      .l2_v(l2_v), .l2_ep(l2_ep), .l2_dec(l2_dec_e), .l2_ok(l2_ok[e]),
      .rs_v(rs_v), .rs_ep(rs_ep), .rs_hit(rs_hit_e), .rs_rep(rs_rep_e), .rs_raw(rs_raw_e), .rs_busy(rs_busy_e),
      .rs_ok(rs_ok[e]),
      .wb_go(wb_go[e]), .st3_wbp(wbp3[e]), .pipe_r(pipe_r[e]), .wb3_r(wb3_r[e]), .wbp_r(wbp_r[e]),
      .wbp_m(wbp_m[e]), .res_v(res_v[e]),
      .ag(agl), .ag_acc(ag_acc_e[e]),
      .tl_tgt(tl_tgt), .tl(tl_l),
      .rb_hi_valid(rb_hi_valid), .rb_hi_rob_idx(rb_hi_rob_idx), .rb_head_valid(rb_head_valid),
      .rb_head_rob_idx(rb_head_rob_idx), .stq_head_tag(stq_head_tag), .unc_busy(unc_busy),
      .mmw_ok(mmw_ok[e]), .mi_pick(mi_oh[e]),
      .dis(dis),
      .l1_tgt(l1_tgt), .l1_launch(l1_launch), .pipe5(pipe5[e]), .dead_r(dead_r[e]),
      .empty8(empty8[e]), .pipe8(pipe8[e]),
      .epoch_nx(epoch_nx[e]),
      .ev_sta(ev_sta), .ev_data(ev_data), .ev_ret(ev_ret), .ev_sc(ev_sc), .alive_post(alive_post),
      .sta_info(sta_info), .sdw(sdw), .fill_v(fill_v), .fill_line(fill_line), .l2w(l2w_e), .full_ok(full_ok[e]),
      .full_cand(full_cand[e]), .rdy9(rdy9[e]), .rp_pick(rp_pick[e]),
      .q_o(q_o[e]), .empty_w(empty_w[e]));
  end

endmodule

`default_nettype wire
