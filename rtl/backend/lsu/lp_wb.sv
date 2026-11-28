// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_lsu2exe_p: direct completions > STA / SC write-back > WBP loads,
`default_nettype none

// Write-back ports of the staged LSU (V2 decoupled WBP + 1-cycle pre-registered lowest-priority SC):
//   Load port p carries, in priority order: L3 direct completion on port p (`wbd_v[p]`), then up to NWBP WBP loads
//   (`wbp_vec`, lowest LDQ index first, parallel 64->NWBP pick), then at most one pre-registered SC result
//   (`sc_req_v_q`). WBP wake-up reads `wp_acc` / `wp_oh` in parallel with `wb_go` and `wb_dest` / `wb_result`.
//   STA completions: oldest NST stores with `wbp`.
module lp_wb
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [NLD-1:0]      wbd_v,
  input  logic [LQW-1:0]      wbd_idx [NLD],
  input  logic [NLD-1:0]      wbd_hasdata,
  input  logic [XLEN_BITS-1:0]         wbd_data [NLD],
  input  lp_ldq_t             ldq_q [LQ],
  input  logic [XLEN_BITS-1:0]         ldq_res [LQ],
  input  logic [LQ-1:0]       wbp_vec,
  input  lp_stq_t             sq [SQ],
  input  logic [SQ-1:0]       alive_w,
  input  logic [CNTW-1:0]     count_q,
  input  logic [SQW-1:0]      head_q,
  input  logic                rsv_valid,
  input  logic [31:0]         rsv_addr,
  output logic [LQ-1:0]       wb_go,               // LDQ entries written back this cycle (freed)
  output logic [LQ-1:0]       wb_go_d,             // ... of them, those of the direct / L3 write-back (not a WBP pick)
  output logic [SQ-1:0]       wb_go_s,             // STQ entries whose STA / SC completion is sent
  output logic [SQ-1:0]       sc_go,
  output logic [NWBP-1:0]     wp_acc,              // accepted WBP picks (to lp_wake for direct one-hot wake-up)
  output logic [LQ-1:0]       wp_oh [NWBP],
  // load write-back ports
  output logic [NLD-1:0]      wb_valid,
  output logic [XLEN_BITS-1:0]         wb_diag [NLD],
  output logic [XLEN_BITS-1:0]         wb_result [NLD],
  output logic [PRFW-1:0]     wb_dest [NLD],
  output logic [ROBW-1:0]     wb_rob [NLD],
  output logic [NLD-1:0]      wb_rob_flag,
  output logic [NLD-1:0]      wb_dest_en,
  output logic [NLD-1:0]      wb_pf_load,
  output logic [NLD-1:0]      wb_pf_store,
  output logic [NLD-1:0]      wb_defer,            // memory speculation: ROB completion deferred
  output logic [NLD-1:0]      wb_flushp,           // memory speculation: final write-back of a violator
  output logic [NLD-1:0]      wb_isw,              // the load is a word load (lw / lwu / flw): flw data is NaN-boxed
  // STA write-back ports
  output logic [NST-1:0]      sta_valid,
  output logic [XLEN_BITS-1:0]         sta_vaddr [NST],
  output logic [ROBW-1:0]     sta_rob [NST],
  output logic [NST-1:0]      sta_rob_flag,
  output logic [NST-1:0]      sta_pf,
  // LR/SC reservation effects (in order: direct LR arms, SC clears, WBP LR arms)
  output logic                lr1_v,
  output logic [31:0]         lr1_addr,
  output logic [ROBW-1:0]     lr1_rob_idx,
  output logic                lr1_rob_flag,
  output logic                sc_clr,
  output logic                lr2_v,
  output logic [31:0]         lr2_addr,
  output logic [ROBW-1:0]     lr2_rob_idx,
  output logic                lr2_rob_flag
);

  localparam int KSC  = 1;
  localparam int NF_W = $clog2(NLD + 1);
  localparam int WC_W = $clog2(NWBP + 1);

  // ---- picks: SC / STA in age order from head, free ports (~wbd_v), WBP loads (64->NWBP) ----
  logic [SQ-1:0]  sc_vec, st_vec, sc_rot, st_rot, alive_unrot;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [SQ-1:0]  sc_oh [KSC], st_oh [NST], st_oh_unrot [NST];
  logic [SQW-1:0] st_ix [NST];
  logic [1:0]     fr_ix [NLD];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [SQW-1:0] sc_ix [KSC];
  logic [KSC-1:0] sc_pv;
  logic [NST-1:0] st_pv;
  logic [LQ-1:0]  wp_oh_w [NWBP];
  logic [LQW-1:0] wp_ix [NWBP];
  logic [NWBP-1:0] wp_pv, wp_acc_w;
  logic [NLD-1:0] free1;
  logic [NF_W-1:0] nfree_l3;
  logic [NLD-1:0] fr_oh [NLD];
  logic [NLD-1:0] fr_pv;
  logic [WC_W-1:0] wp_cnt;

  // Algebraic identity: rotr64(vec & rotl64(alive_unrot, head_q), head_q) == alive_unrot & rotr64(vec, head_q).
  always_comb begin
    for (int j = 0; j < SQ; j++) begin
      alive_unrot[j] = (CNTW'(j) < count_q);
      sc_vec[j] = sq[j].wbp && sq[j].lrsc;
      st_vec[j] = sq[j].wbp && !sq[j].lrsc;
    end
    free1  = ~wbd_v;
    sc_rot = alive_unrot & SQ'(rotr64(64'(sc_vec), head_q));
    st_rot = alive_unrot & SQ'(rotr64(64'(st_vec), head_q));
  end
  lp_pickn #(.N(SQ),  .K(KSC))  u_sc (.vec(sc_rot),  .onehot(sc_oh),   .idx(sc_ix), .v(sc_pv));
  lp_pickn #(.N(SQ),  .K(NST))  u_st (.vec(st_rot),  .onehot(st_oh),   .idx(st_ix), .v(st_pv));
  lp_pickn #(.N(NLD), .K(NLD))  u_fr (.vec(free1),   .onehot(fr_oh),   .idx(fr_ix), .v(fr_pv));
  ttg_popcount #(.N(NLD), .CW(NF_W))  u_nf  (.bits(free1),    .count(nfree_l3));
  lp_pickn #(.N(LQ),  .K(NWBP)) u_wp (.vec(wbp_vec), .onehot(wp_oh_w), .idx(wp_ix), .v(wp_pv));

  // 1-cycle pre-registered SC request (decouples rotr64(sq) -> u_sc from WBP and wake-up)
  logic           sc_req_v_q;
  logic [SQW-1:0] sc_req_idx_q;
  logic           sc_req_live, sc_fire;
  assign sc_req_live = sc_req_v_q && alive_w[sc_req_idx_q] &&
                       sq[sc_req_idx_q].wbp && sq[sc_req_idx_q].lrsc;
  always_ff @(posedge clk) begin
    if (!rst_n || flush || mispred) begin
      sc_req_v_q   <= 1'b0;
      sc_req_idx_q <= '0;
    end else if (sc_req_live) begin
      sc_req_v_q   <= !sc_fire;
    end else begin
      sc_req_v_q   <= sc_pv[0];
      sc_req_idx_q <= sc_ix[0] + head_q;
    end
  end

  always_comb begin
    for (int m = 0; m < NST; m++) st_oh_unrot[m] = SQ'(rotl64(64'(st_oh[m]), head_q));
    for (int m = 0; m < NWBP; m++) wp_acc_w[m] = wp_pv[m] && (nfree_l3 > NF_W'(m));
  end
  assign wp_acc = wp_acc_w;
  assign wp_oh  = wp_oh_w;
  ttg_popcount #(.N(NWBP), .CW(WC_W)) u_wpc (.bits(wp_acc_w), .count(wp_cnt));

  // ---- what each load port carries: L3 direct > WBP > lowest-priority pre-registered SC ----
  logic [NLD-1:0] sc_port_oh, kind_sc, kind_wp;
  logic [LQW-1:0] wp_idx_p [NLD];
  logic [LQW-1:0] ld_i [NLD];
  logic [NLD-1:0] ld_v;
  always_comb begin
    sc_fire    = 1'b0;
    sc_port_oh = '0;
    for (int p = 0; p < NLD; p++) begin
      if (sc_req_live && (int'(wp_cnt) == p) && fr_pv[p]) begin
        sc_fire    = 1'b1;
        sc_port_oh = fr_oh[p];
      end
    end
    kind_sc = '0;
    kind_wp = '0;
    for (int p = 0; p < NLD; p++) begin
      wp_idx_p[p] = '0;
      if (sc_fire && sc_port_oh[p]) kind_sc[p] = 1'b1;
      for (int m = 0; m < NWBP; m++) begin
        if (wp_acc_w[m] && fr_oh[m][p]) begin
          kind_wp[p]  = 1'b1;
          wp_idx_p[p] = wp_ix[m];
        end
      end
      ld_v[p] = wbd_v[p] || kind_wp[p];
      ld_i[p] = wbd_v[p] ? wbd_idx[p] : wp_idx_p[p];
    end
  end

  logic [XLEN_BITS-1:0] ld_res [NLD];
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
      wb_rob[p] = '0;
      wb_rob_flag[p] = 1'b0;
      wb_dest_en[p] = 1'b0;
      wb_pf_load[p] = 1'b0;
      wb_pf_store[p] = 1'b0;
      wb_defer[p] = 1'b0;
      wb_flushp[p] = 1'b0;
      wb_isw[p] = 1'b0;
      if (ld_v[p]) begin
        wb_defer[p] = !ldq_q[ld_i[p]].second && ldq_q[ld_i[p]].spec && !ldq_q[ld_i[p]].pf &&
                      !ldq_q[ld_i[p]].mmio && !ldq_q[ld_i[p]].lrsc;
        wb_flushp[p] = ldq_q[ld_i[p]].second && ldq_q[ld_i[p]].vio;
        wb_diag[p] = ldq_q[ld_i[p]].vaddr;
        wb_isw[p] = (ldq_q[ld_i[p]].func3[1:0] == 2'd2);
        wb_result[p] = ldq_q[ld_i[p]].pf ? ldq_q[ld_i[p]].vaddr : ld_res[p];
        // a faulting load does not write its destination (architecturally rd is unchanged; like the SC fault below)
        wb_dest[p] = ldq_q[ld_i[p]].pf ? PRFW'(0) : ldq_q[ld_i[p]].dest_preg;
        wb_rob[p] = ldq_q[ld_i[p]].rob_idx;
        wb_rob_flag[p] = ldq_q[ld_i[p]].rob_flag;
        wb_dest_en[p] = !ldq_q[ld_i[p]].pf && ldq_q[ld_i[p]].dest_preg != '0;
        wb_pf_load[p] = ldq_q[ld_i[p]].pf;
      end else if (kind_sc[p]) begin
        wb_diag[p] = sq[sc_req_idx_q].vaddr;
        wb_result[p] = sq[sc_req_idx_q].pf ? sq[sc_req_idx_q].vaddr
                                           : ((rsv_valid && rsv_addr == sq[sc_req_idx_q].paddr)
                                              ? XLEN_BITS'(0) : XLEN_BITS'(1));
        wb_dest[p] = sq[sc_req_idx_q].pf ? PRFW'(0) : sq[sc_req_idx_q].dest_preg;
        wb_rob[p] = sq[sc_req_idx_q].rob_idx;
        wb_rob_flag[p] = sq[sc_req_idx_q].rob_flag;
        wb_dest_en[p] = !sq[sc_req_idx_q].pf && sq[sc_req_idx_q].dest_preg != '0;
        wb_pf_store[p] = sq[sc_req_idx_q].pf;
      end
    end
  end

  // ---- bookkeeping: direct one-hot wb_go (zero wp_ix -> decoder loop) and STQ completions ----
  always_comb begin
    wb_go_d = '0;
    for (int p = 0; p < NLD; p++) if (wbd_v[p]) wb_go_d[wbd_idx[p]] = 1'b1;
    wb_go = wb_go_d;
    for (int m = 0; m < NWBP; m++) if (wp_acc_w[m]) wb_go = wb_go | wp_oh_w[m];
    wb_go_s = '0;
    sc_go = '0;
    for (int m = 0; m < NST; m++) if (st_pv[m]) wb_go_s = wb_go_s | st_oh_unrot[m];
    if (sc_fire) begin
      wb_go_s[sc_req_idx_q] = 1'b1;
      if (!sq[sc_req_idx_q].pf) sc_go[sc_req_idx_q] = 1'b1;
    end
  end

  // ---- LR/SC reservation ----
  always_comb begin
    lr1_v = 1'b0;
    lr1_addr = '0;
    lr1_rob_idx = '0;
    lr1_rob_flag = 1'b0;
    lr2_v = 1'b0;
    lr2_addr = '0;
    lr2_rob_idx = '0;
    lr2_rob_flag = 1'b0;
    sc_clr = |sc_go;
    for (int p = 0; p < NLD; p++) begin
      if (wbd_v[p] && ldq_q[wbd_idx[p]].lrsc && !ldq_q[wbd_idx[p]].pf) begin
        lr1_v = 1'b1;
        lr1_addr = ldq_q[wbd_idx[p]].paddr;
        lr1_rob_idx = ldq_q[wbd_idx[p]].rob_idx;
        lr1_rob_flag = ldq_q[wbd_idx[p]].rob_flag;
      end
      if (kind_wp[p] && ldq_q[wp_idx_p[p]].lrsc && !ldq_q[wp_idx_p[p]].pf) begin
        lr2_v = 1'b1;
        lr2_addr = ldq_q[wp_idx_p[p]].paddr;
        lr2_rob_idx = ldq_q[wp_idx_p[p]].rob_idx;
        lr2_rob_flag = ldq_q[wp_idx_p[p]].rob_flag;
      end
    end
  end

  typedef struct packed {
    logic [XLEN_BITS-1:0] vaddr;
    logic [ROBW-1:0]      rob_idx;
    logic                 rob_flag;
    logic                 pf;
  } lp_sta_wb_t;
  lp_sta_wb_t sq_sta_v [SQ], sta_sel [NST];
  always_comb begin
    for (int j = 0; j < SQ; j++) begin
      sq_sta_v[j].vaddr    = sq[j].vaddr;
      sq_sta_v[j].rob_idx  = sq[j].rob_idx;
      sq_sta_v[j].rob_flag = sq[j].rob_flag;
      sq_sta_v[j].pf       = sq[j].pf;
    end
  end
  for (genvar m = 0; m < NST; m++) begin : g_sta
    ttg_onehot_mux #(.N(SQ), .W($bits(lp_sta_wb_t))) u_stamux (
      .sel(st_oh_unrot[m]), .data(sq_sta_v), .out(sta_sel[m])
    );
    assign sta_valid[m]    = st_pv[m];
    assign sta_vaddr[m]    = sta_sel[m].vaddr;
    assign sta_rob[m]      = sta_sel[m].rob_idx;
    assign sta_rob_flag[m] = sta_sel[m].rob_flag;
    assign sta_pf[m]       = sta_sel[m].pf;
  end

endmodule

`default_nettype wire
