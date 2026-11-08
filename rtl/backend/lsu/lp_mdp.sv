// Ref: back-end/Lsu/RealLsuPipe.cpp  mdp_wait / mdp_write_pending / comb_dis2lsu_p (wait table, mode 0)
`default_nettype none

// Memory-dependence predictor of the staged LSU: a wait table of 2^MDPW one-bit entries indexed by a hash of the
// load PC (model: LSU_MDP_MODE 0, THR 1, DEC 0, LSU_MDP_HW 2).
//   lookup : at dispatch, one read port per load slot; the bit goes into the LDQ entry (a load whose bit is set
//            does not pass unknown-address stores)
//   train  : a load that violated sets its bit, one write port (LSU_MDP_HW=2 in the model): flagged in a register,
//            the lowest flagged live entry trains per cycle, written at the clock edge
//   clear  : lazily, at the first load dispatch LSU_MDP_CLR cycles after the previous clear (a saturating down
//            counter); the lookups of that cycle already see the cleared table, the trains of that cycle survive
module lp_mdp
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  lp_dis_ld_t          dis [NDIS],
  input  logic [LQ-1:0]       vio_new,
  input  logic [LQ-1:0]       empty_w,
  input  lp_ldq_t             ldq_q [LQ],
  output logic [NDIS-1:0]     dis_wait
);

  localparam int TW = $clog2(LSU_MDP_CLR + 1);

  logic [(1<<MDPW)-1:0] tab_q, tab_d, tr_mask;
  logic [TW-1:0]        tmr_q;
  logic                 any_dis, clr_en;

  always_comb begin
    any_dis = 1'b0;
    for (int i = 0; i < NDIS; i++) any_dis = any_dis | dis[i].v;
    clr_en = (LSU_MDP_CLR != 0) && any_dis && tmr_q == '0;
    for (int i = 0; i < NDIS; i++) dis_wait[i] = tab_q[dis[i].mdp] && !clr_en;
  end

  // train: the violators are flagged in a register (trn_q, one bit per LDQ entry); every cycle the lowest flagged live
  // entry writes its bit (so the table is written two cycles after the violation, from registers only); the flag of an
  // entry that died (EMPTY) is dropped
  logic [LQ-1:0]  trn_q, trn_live, tr_oh;
  logic [LQW-1:0] tr_ix;
  logic           tr_v;
  assign trn_live = trn_q & ~empty_w;
  lp_ffs #(.N(LQ)) u_tr (.req(trn_live), .onehot(tr_oh), .any(tr_v));
  ttg_onehot_to_idx #(.N(LQ)) u_trx (.onehot(tr_oh), .idx(tr_ix));
  always_comb begin
    tr_mask = '0;
    if (tr_v) tr_mask[ldq_q[tr_ix].mdp] = 1'b1;
    tab_d = (clr_en ? '0 : tab_q) | tr_mask;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tab_q <= '0;
      tmr_q <= '0;
      trn_q <= '0;
    end else begin
      tab_q <= tab_d;
      trn_q <= (trn_live & ~tr_oh) | vio_new;
      if (clr_en) tmr_q <= TW'(LSU_MDP_CLR - 1);
      else if (tmr_q != '0) tmr_q <= tmr_q - TW'(1);
    end
  end

endmodule

`default_nettype wire
