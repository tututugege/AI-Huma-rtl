// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LSU_MEMSPEC: SPD release scan, STA arrival view, wait-table lookup)
`default_nettype none

// Memory-dependence speculation helpers of the staged LSU:
//   unk_any / unk_rank : the oldest store (rank from the STQ head) without an address; an SPD load is released when no
//                        store older than itself is unknown (older count <= unk_rank), see lp_ldq_ent
//   sa_*               : the STA arrivals of this cycle as seen by the violation check of every LDQ entry
//   dis_ldw            : the allocation requests with the wait-table bit of the load PC
module lp_ms
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  /* verilator lint_off UNUSEDSIGNAL */  // clk, rst_n, vio_new feed the wait table (LSU_MEMSPEC only)
  input  logic                clk,
  input  logic                rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  lp_stq_t             sq [SQ],
  input  logic [SQW-1:0]      head_q,
  input  lp_agu_st_t          ags [NST],
  input  lp_dis_ld_t          dis_ld [NDIS],
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [LQ-1:0]       vio_new,
  /* verilator lint_on UNUSEDSIGNAL */
  input  lp_ldq_t             ldq_q [LQ],
  input  lp_l1in_t            l1 [NLD],
  output logic [NLD-1:0]      spec_ok,
  output logic                unk_any,
  output logic [SQW-1:0]      unk_rank,
  output logic [SQW-1:0]      sa_rank [NST],
  output logic [11:0]         sa_voff [NST],
  output logic [2:0]          sa_f3 [NST],
  output lp_dis_ld_t          dis_ldw [NDIS]
);

  logic [SQ-1:0]   unk_vec, unk_rot, unk_oh;
  logic [NDIS-1:0] mdp_wait;

  always_comb begin
    for (int j = 0; j < SQ; j++) unk_vec[j] = !sq[j].va_v && !sq[j].suppress;
    unk_rot = SQ'(rotr64(64'(unk_vec), head_q));
    for (int k = 0; k < NST; k++) begin
      sa_rank[k] = ags[k].stq - head_q;
      sa_voff[k] = ags[k].vaddr[11:0];
      sa_f3[k] = ags[k].func3;
    end
    for (int k = 0; k < NLD; k++)   // may pass unknown-address stores unless LR, second pass or predicted to wait
      spec_ok[k] = MS && !ldq_q[l1[k].ldq].second && !l1[k].lrsc && !ldq_q[l1[k].ldq].wait_b;
    for (int i = 0; i < NDIS; i++) begin
      dis_ldw[i] = dis_ld[i];
      dis_ldw[i].wait_b = mdp_wait[i];
    end
  end
  lp_ffs #(.N(SQ)) u_unk (.req(unk_rot), .onehot(unk_oh), .any(unk_any));
  ttg_onehot_to_idx #(.N(SQ)) u_unkx (.onehot(unk_oh), .idx(unk_rank));

  if (MS) begin : g_mdp
    lp_mdp u_mdp (.clk(clk), .rst_n(rst_n), .dis(dis_ld), .vio_new(vio_new), .ldq_q(ldq_q), .dis_wait(mdp_wait));
  end else begin : g_nomdp
    assign mdp_wait = '0;
  end

endmodule

`default_nettype wire
