// Ref: back-end/Lsu/RealLsuPipe.cpp  mdp_wait / mdp_write_pending / comb_dis2lsu_p (wait table, mode 0)
`default_nettype none

// Memory-dependence predictor of the staged LSU: a wait table of 2^MDPW one-bit entries indexed by a hash of the
// load PC (model: LSU_MDP_MODE 0, THR 1, DEC 0, LSU_MDP_HW 1).
//   lookup : at dispatch, one read port per load slot; the bit goes into the LDQ entry (a load whose bit is set
//            does not pass unknown-address stores)
//   train  : a load that violated sets its bit; MDPN write ports, the lowest LDQ indices of the cycle first; the
//            bit is written at the clock edge (the lookups of the next cycle see it)
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

  // train: the MDPN lowest violating LDQ entries
  /* verilator lint_off UNUSEDSIGNAL */  // primitive output not needed here
  logic [LQ-1:0]   tr_oh [MDPN];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [LQW-1:0]  tr_ix [MDPN];
  logic [MDPN-1:0] tr_v;
  lp_pickn #(.N(LQ), .K(MDPN)) u_tr (.vec(vio_new), .onehot(tr_oh), .idx(tr_ix), .v(tr_v));
  always_comb begin
    tr_mask = '0;
    for (int m = 0; m < MDPN; m++) if (tr_v[m]) tr_mask[ldq_q[tr_ix[m]].mdp] = 1'b1;
    tab_d = (clr_en ? '0 : tab_q) | tr_mask;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tab_q <= '0;
      tmr_q <= '0;
    end else begin
      tab_q <= tab_d;
      if (clr_en) tmr_q <= TW'(LSU_MDP_CLR - 1);
      else if (tmr_q != '0) tmr_q <= tmr_q - TW'(1);
    end
  end

endmodule

`default_nettype wire
