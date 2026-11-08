// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_lsu2exe_p: direct completions > STA / SC write-back > WBP loads,
`default_nettype none

// Write-back ports of the staged LSU.  Load port p carries, in this order of priority: the direct completion of its own
// pipeline (L2 forward / page fault, DCache hit), then SC results (free ports, ascending), then WBP loads (lowest LDQ
// index first, the ports left).  STA completions: the oldest NST stores with `wbp` (SC through a load port).
module lp_wb
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic [NLD-1:0]      wbd_v,
  input  logic [LQW-1:0]      wbd_idx [NLD],
  input  logic [NLD-1:0]      wbd_hasdata,
  input  logic [31:0]         wbd_data [NLD],
  input  lp_ldq_t             ldq_q [LQ],
  input  logic [31:0]         ldq_res [LQ],
  input  logic [LQ-1:0]       wbp_vec,
  input  lp_stq_t             sq [SQ],
  input  logic [SQ-1:0]       alive_w,
  input  logic [SQW-1:0]      head_q,
  input  logic                rsv_valid,
  input  logic [31:0]         rsv_addr,
  output logic [LQ-1:0]       wb_go,               // LDQ entries written back this cycle (freed)
  output logic [LQ-1:0]       wb_go_d,             // ... of them, those of the direct / L3 write-back (not a WBP pick)
  output logic [SQ-1:0]       wb_go_s,             // STQ entries whose STA / SC completion is sent
  output logic [SQ-1:0]       sc_go,
  // load write-back ports
  output logic [NLD-1:0]      wb_valid,
  output logic [31:0]         wb_diag [NLD],
  output logic [31:0]         wb_result [NLD],
  output logic [PRFW-1:0]     wb_dest [NLD],
  output logic [BRW-1:0]      wb_br [NLD],
  output logic [ROBW-1:0]     wb_rob [NLD],
  output logic [NLD-1:0]      wb_dest_en,
  output logic [NLD-1:0]      wb_pf_load,
  output logic [NLD-1:0]      wb_pf_store,
  output logic [NLD-1:0]      wb_defer,            // memory speculation: ROB completion deferred
  output logic [NLD-1:0]      wb_flushp,           // memory speculation: final write-back of a violator
  // STA write-back ports
  output logic [NST-1:0]      sta_valid,
  output logic [31:0]         sta_vaddr [NST],
  output logic [BRW-1:0]      sta_br [NST],
  output logic [ROBW-1:0]     sta_rob [NST],
  output logic [NST-1:0]      sta_pf,
  // LR/SC reservation effects (in order: direct LR arms, SC clears, WBP LR arms)
  output logic                lr1_v,
  output logic [31:0]         lr1_addr,
  output logic [BRW-1:0]      lr1_br,
  output logic                sc_clr,
  output logic                lr2_v,
  output logic [31:0]         lr2_addr,
  output logic [BRW-1:0]      lr2_br
);

  // LP_L2[6]: at most one SC completion per cycle (the pick is one find-first instead of NLD chained ones)
  localparam int KSC = ((LP_L2 & 64) != 0) ? 1 : NLD;
  // ---- picks: SC / STA in age order from the head, free ports, WBP loads in index order ----
  logic [SQ-1:0]  sc_vec, st_vec, sc_rot, st_rot;
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [SQ-1:0]  sc_oh [KSC], st_oh [NST];
  logic [SQW-1:0] sc_ix [KSC], st_ix [NST];
  logic [KSC-1:0] sc_pv;
  logic [NST-1:0] st_pv;
  logic [LQ-1:0]  wp_oh [NLD];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [LQW-1:0] wp_ix [NLD];
  logic [NLD-1:0] wp_pv;
  logic [NLD-1:0] free1, free2;
  logic [NLD-1:0] fr_oh [NLD], f2_oh [NLD];
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [1:0]     fr_ix [NLD], f2_ix [NLD];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NLD-1:0] fr_pv, f2_pv;
  logic [NLD-1:0] sc_acc, wp_acc;
  logic [SQW-1:0] sc_abs [NLD], st_abs [NST];

  always_comb begin
    for (int j = 0; j < SQ; j++) begin
      sc_vec[j] = sq[j].wbp && sq[j].lrsc && alive_w[j];
      st_vec[j] = sq[j].wbp && !sq[j].lrsc && alive_w[j];
    end
    free1 = ~wbd_v;
    sc_rot = SQ'(rotr64(64'(sc_vec), head_q));
    st_rot = SQ'(rotr64(64'(st_vec), head_q));
  end
  lp_pickn #(.N(SQ), .K(KSC)) u_sc (.vec(sc_rot), .onehot(sc_oh), .idx(sc_ix), .v(sc_pv));
  lp_pickn #(.N(SQ), .K(NST)) u_st (.vec(st_rot), .onehot(st_oh), .idx(st_ix), .v(st_pv));
  lp_pickn #(.N(NLD), .K(NLD)) u_fr (.vec(free1), .onehot(fr_oh), .idx(fr_ix), .v(fr_pv));
  lp_pickn #(.N(LQ), .K(NLD)) u_wp (.vec(wbp_vec), .onehot(wp_oh), .idx(wp_ix), .v(wp_pv));
  lp_pickn #(.N(NLD), .K(NLD)) u_f2 (.vec(free2), .onehot(f2_oh), .idx(f2_ix), .v(f2_pv));

  always_comb begin
    free2 = free1;
    sc_acc = '0;
    for (int m = 0; m < NLD; m++) sc_abs[m] = '0;
    for (int m = 0; m < KSC; m++) begin
      sc_acc[m] = sc_pv[m] && fr_pv[m];       // the m-th SC needs the m-th free port
      sc_abs[m] = sc_ix[m] + head_q;
      if (sc_acc[m]) free2 = free2 & ~fr_oh[m];
    end
    for (int m = 0; m < NST; m++) st_abs[m] = st_ix[m] + head_q;
    for (int m = 0; m < NLD; m++) wp_acc[m] = wp_pv[m] && f2_pv[m];
  end

  // ---- what each load port carries ----
  logic [NLD-1:0] kind_sc, kind_wp;
  logic [SQW-1:0] sc_idx_p [NLD];
  logic [LQW-1:0] wp_idx_p [NLD];
  always_comb begin
    kind_sc = '0;
    kind_wp = '0;
    for (int p = 0; p < NLD; p++) begin
      sc_idx_p[p] = '0;
      wp_idx_p[p] = '0;
      for (int m = 0; m < NLD; m++) begin
        if (sc_acc[m] && fr_oh[m][p]) begin
          kind_sc[p] = 1'b1;
          sc_idx_p[p] = sc_abs[m];
        end
        if (wp_acc[m] && f2_oh[m][p]) begin
          kind_wp[p] = 1'b1;
          wp_idx_p[p] = wp_ix[m];
        end
      end
    end
  end

  logic [LQW-1:0] ld_i [NLD];             // LDQ entry of the port (direct or WBP)
  logic [NLD-1:0] ld_v;                   // the port carries a load
  always_comb begin
    for (int p = 0; p < NLD; p++) begin
      ld_v[p] = wbd_v[p] || kind_wp[p];
      ld_i[p] = wbd_v[p] ? wbd_idx[p] : wp_idx_p[p];
    end
  end

  logic [31:0] ld_res [NLD];
  always_comb begin
    for (int p = 0; p < NLD; p++) begin
      ld_res[p] = (wbd_v[p] && wbd_hasdata[p]) ? wbd_data[p] : ldq_res[ld_i[p]];
    end
  end

  always_comb begin
    for (int p = 0; p < NLD; p++) begin
      wb_valid[p] = ld_v[p] || kind_sc[p];
      wb_diag[p] = '0;
      wb_result[p] = '0;
      wb_dest[p] = '0;
      wb_br[p] = '0;
      wb_rob[p] = '0;
      wb_dest_en[p] = 1'b0;
      wb_pf_load[p] = 1'b0;
      wb_pf_store[p] = 1'b0;
      wb_defer[p] = 1'b0;
      wb_flushp[p] = 1'b0;
      if (ld_v[p]) begin
        wb_defer[p] = MS && !ldq_q[ld_i[p]].second && ldq_q[ld_i[p]].spec && !ldq_q[ld_i[p]].pf &&
                      !ldq_q[ld_i[p]].mmio && !ldq_q[ld_i[p]].lrsc;
        wb_flushp[p] = MS && ldq_q[ld_i[p]].second && ldq_q[ld_i[p]].vio;
        wb_diag[p] = ldq_q[ld_i[p]].vaddr;
        wb_result[p] = ldq_q[ld_i[p]].pf ? ldq_q[ld_i[p]].vaddr : ld_res[p];
        wb_dest[p] = ldq_q[ld_i[p]].dest_preg;
        wb_br[p] = ldq_q[ld_i[p]].br_mask;
        wb_rob[p] = ldq_q[ld_i[p]].rob_idx;
        wb_dest_en[p] = ldq_q[ld_i[p]].dest_preg != '0;
        wb_pf_load[p] = ldq_q[ld_i[p]].pf;
      end else if (kind_sc[p]) begin
        wb_diag[p] = sq[sc_idx_p[p]].vaddr;
        wb_result[p] = sq[sc_idx_p[p]].pf ? sq[sc_idx_p[p]].vaddr
                                          : ((rsv_valid && rsv_addr == sq[sc_idx_p[p]].paddr) ? 32'd0 : 32'd1);
        wb_dest[p] = sq[sc_idx_p[p]].pf ? PRFW'(0) : sq[sc_idx_p[p]].dest_preg;
        wb_br[p] = sq[sc_idx_p[p]].br_mask;
        wb_rob[p] = sq[sc_idx_p[p]].rob_idx;
        wb_dest_en[p] = !sq[sc_idx_p[p]].pf && sq[sc_idx_p[p]].dest_preg != '0;
        wb_pf_store[p] = sq[sc_idx_p[p]].pf;
      end
    end
  end

  // ---- bookkeeping: freed LDQ entries, STQ completions ----
  always_comb begin
    wb_go = '0;
    wb_go_d = '0;
    for (int p = 0; p < NLD; p++) if (ld_v[p]) wb_go[ld_i[p]] = 1'b1;
    for (int p = 0; p < NLD; p++) if (wbd_v[p]) wb_go_d[wbd_idx[p]] = 1'b1;
    wb_go_s = '0;
    sc_go = '0;
    for (int m = 0; m < NST; m++) if (st_pv[m]) wb_go_s[st_abs[m]] = 1'b1;
    for (int m = 0; m < KSC; m++) begin
      if (sc_acc[m]) begin
        wb_go_s[sc_abs[m]] = 1'b1;
        if (!sq[sc_abs[m]].pf) sc_go[sc_abs[m]] = 1'b1;
      end
    end
  end

  // ---- LR/SC reservation ----
  always_comb begin
    lr1_v = 1'b0;
    lr1_addr = '0;
    lr1_br = '0;
    lr2_v = 1'b0;
    lr2_addr = '0;
    lr2_br = '0;
    sc_clr = |sc_go;
    for (int p = 0; p < NLD; p++) begin
      if (wbd_v[p] && ldq_q[wbd_idx[p]].lrsc && !ldq_q[wbd_idx[p]].pf) begin
        lr1_v = 1'b1;
        lr1_addr = ldq_q[wbd_idx[p]].paddr;
        lr1_br = ldq_q[wbd_idx[p]].br_mask;
      end
      if (kind_wp[p] && ldq_q[wp_idx_p[p]].lrsc && !ldq_q[wp_idx_p[p]].pf) begin
        lr2_v = 1'b1;
        lr2_addr = ldq_q[wp_idx_p[p]].paddr;
        lr2_br = ldq_q[wp_idx_p[p]].br_mask;
      end
    end
  end

  for (genvar m = 0; m < NST; m++) begin : g_sta
    assign sta_valid[m] = st_pv[m];
    assign sta_vaddr[m] = sq[st_abs[m]].vaddr;
    assign sta_br[m] = sq[st_abs[m]].br_mask;
    assign sta_rob[m] = sq[st_abs[m]].rob_idx;
    assign sta_pf[m] = sq[st_abs[m]].pf;
  end

endmodule

`default_nettype wire
