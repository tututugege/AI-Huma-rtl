// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (PLdq: staged LDQ entry; comb_*_p phases applied in the BackTop order)
`default_nettype none

// One LDQ entry of the staged LSU.  The glue decodes, per cycle, which events hit this entry; the entry applies them in
// the order of the model (P2 mmio_in, P3 L2, P5 write-back, P6 AGU, P8 DTLB, P9 MMIO issue, P10 alloc, P11 flush,
// P12 launch, P13 wake-up, P14 replay-register pick), so one cycle can move an entry through several states.
module lp_ldq_ent
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
#(
  parameter int IDX = 0
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [ROBW-1:0]     dec_rob_idx,
  input  logic                dec_rob_flag,
  // P2 MMIO response
  input  logic                mm_go,
  input  logic [XLEN_BITS-1:0]         mm_data,
  // P3a L2 decision of the port that targets this entry
  input  logic                l2_v,
  input  logic [EPW-1:0]      l2_ep,
  input  lp_l2dec_t           l2_dec,
  output logic                l2_ok,
  // P3b DCache response that targets this entry
  input  logic                rs_v,
  input  logic [EPW-1:0]      rs_ep,
  input  logic                rs_hit,
  input  logic [1:0]          rs_rep,
  input  logic [XLEN_BITS-1:0]         rs_raw,
  input  logic                rs_busy,             // the response port already carries an L2 write-back
  output logic                rs_ok,
  // P5 write-back
  input  logic                wb_go,
  input  logic                wb_go_d,             // the write-back comes from the direct / L3 path (not a WBP pick)
  input  logic [XLEN_BITS-1:0]         wb_d_data,           // ... and its data (kept when the completion is deferred)
  output logic [XLEN_BITS-1:0]         res_v,               // result as seen by the write-back (after P2 / P3)
  // memory speculation: store-queue view (registers) for the SPD release and the violation check
  input  logic [SQW:0]        head_tag,
  input  logic [CNTW-1:0]     count_q,
  input  logic                unk_any,             // some store of the STQ ring has no address yet
  input  logic [SQW-1:0]      unk_rank,            // rank (from the head) of the oldest such store
  input  logic [NST-1:0]      sa_v,                // accepted STA arrivals of this cycle
  input  logic [SQW-1:0]      sa_rank [NST],       // their rank from the head
  input  logic [11:0]         sa_voff [NST],
  input  logic [2:0]          sa_f3 [NST],
  input  logic                sp_we,               // L1 CAM result for this entry: spec flag update
  input  logic                sp_val,
  output logic                vio_new,             // the entry became a violator in this cycle
  // P6 AGU arrivals
  input  lp_agu_ld_t          ag [NLD],
  output logic [NLD-1:0]      ag_acc,
  // P8 DTLB result of the L1 slots
  input  logic [NLD-1:0]      tl_tgt,              // slot k targets this entry and asked the DTLB
  input  lp_tl_t              tl [NLD],
  // P9 MMIO load issue
  input  logic                rb_hi_valid,
  input  logic [ROBW-1:0]     rb_hi_rob_idx,
  input  logic                rb_head_valid,
  input  logic [ROBW-1:0]     rb_head_rob_idx,
  input  logic [SQW:0]        stq_head_tag,
  input  logic                unc_busy,
  output logic                mmw_ok,
  input  logic                mi_pick,
  // P10 dispatch allocation
  input  lp_dis_ld_t          dis [NDIS],
  // P12 launch
  input  logic [NLD-1:0]      l1_tgt,
  input  logic [NLD-1:0]      l1_launch,
  output logic                pipe_r,              // registered state == PIPE
  output logic                wb3_r,               // registered state == WB3 (L3 register of the port holds it)
  output logic                wbp_r,               // registered state == WBP
  output logic                wbp_m,               // MMIO response of this cycle: MMR -> WBP
  output logic                dead_r,              // killed by this cycle's flush / mispredict (registered fields only)
  output logic [EPW-1:0]      epoch_nx,
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
  input  lp_wk_t              l2w,                 // LP_L2[8]: wake-up outcome of the load parked now
  input  logic                full_ok,
  output logic                full_cand,
  // P14 replay register pick
  output logic                rdy9,
  input  logic                rp_pick,
  // state
  output lp_ldq_t             q_o,
  output logic                empty_w
);

  lp_ld_st_t   st_q;
  lp_ldq_t     f_q;
  logic        al;
  /* verilator lint_off UNUSEDSIGNAL */  // only the fields used by this entry are read
  lp_dis_ld_t  al_d;
  /* verilator lint_on UNUSEDSIGNAL */

  assign q_o     = f_q;
  assign empty_w = st_q == LS_EMPTY;
  // ---- decode of the arrivals / allocation ----
  logic [NLD-1:0] ag_hit;
  /* verilator lint_off UNUSEDSIGNAL */
  lp_agu_ld_t     ag_s;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NDIS-1:0] al_hit;
  always_comb begin
    ag_s = '0;
    for (int i = 0; i < NLD; i++) begin
      ag_hit[i] = ag[i].v && ag[i].ldq == LQW'(IDX);
      ag_acc[i] = ag_hit[i] && ag[i].rob_idx == f_q.rob_idx && ag[i].rob_flag == f_q.rob_flag;
      if (ag_acc[i]) ag_s = ag[i];
    end
    al_d = '0;
    for (int i = 0; i < NDIS; i++) begin
      al_hit[i] = dis[i].v && dis[i].ldq == LQW'(IDX);
      if (al_hit[i]) al_d = dis[i];
    end
    al = |al_hit;
  end

  // ---- state chain P2 .. P3 ----
  lp_ld_st_t st1, st2, st3;
  logic      park_a, park_b;
  always_comb begin
    st1 = st_q;
    if (mm_go && st_q == LS_MMR) st1 = LS_WBP;
    l2_ok = l2_v && st1 == LS_PIPE && f_q.epoch == l2_ep;
    park_a = l2_ok && l2_dec.act == L2_PARK;
    st2 = st1;
    if (l2_ok) begin
      case (l2_dec.act)
        L2_PARK: st2 = LS_RPW;
        L2_MMW:  st2 = LS_MMW;
        L2_DCW:  st2 = LS_DCW;
        L2_RDY:  st2 = LS_RDY;
        L2_WBP:  st2 = LS_WBP;
        L2_WBD:  st2 = LS_WB3;
        default: st2 = st1;
      endcase
    end
    rs_ok = rs_v && st2 == LS_DCW && f_q.epoch == rs_ep;
    park_b = rs_ok && !rs_hit;
    st3 = st2;
    if (rs_ok && rs_hit && rs_busy) st3 = LS_WBP;
    else if (rs_ok && rs_hit)       st3 = LS_WB3;
    if (park_b) st3 = LS_RPW;
    wbp_m = mm_go && st_q == LS_MMR;
  end

  // ---- fields after P3 (park information, rtype) ----
  logic [2:0]     rc3;
  logic [SQW-1:0] blk3;
  logic [RWW-1:0] wt3;
  logic [1:0]     rt3;
  logic [XLEN_BITS-1:0]    res3;
  always_comb begin
    rc3 = f_q.rcause;
    blk3 = f_q.blk;
    wt3 = f_q.rwait;
    rt3 = f_q.rtype;
    res3 = f_q.result;
    if (mm_go && st_q == LS_MMR) res3 = mm_data;
    if (park_a) begin
      rc3 = l2_dec.cause;
      blk3 = l2_dec.blk;
      wt3 = l2_dec.wait_c;
    end
    if (rs_ok) rt3 = rs_rep;
    if (rs_ok && rs_hit && rs_busy) res3 = lsu_pkg::extract_data(rs_raw, f_q.paddr[lsu_pkg::OW-1:0], f_q.func3);
    if (park_b) begin
      rc3 = 3'(RC_DC);
      blk3 = '0;
      wt3 = replay_wait(rs_rep);
    end
    // LP_CUT[3]: lp_wb never picks a newly-WBP rs_ok entry in the same cycle; cut false path rs_busy -> res_v -> wb_result
    res_v = (mm_go && st_q == LS_MMR) ? mm_data : f_q.result;
  end

  // ---- P5 .. P9: write-back frees, AGU arrival, DTLB result, MMIO issue ----
  lp_ld_st_t st4, st4v, st5, st6;
  logic      dfr, sec4v, vio_n;
  logic      tl_hit, tl_pf;
  logic [31:0] tl_pa;
  logic [XLEN_BITS-1:0] vaddr6;
  lp_tl_t    tl_s;
  assign st4 = wb_go ? LS_EMPTY : st3;
  logic sp_we_eff, spec_p3;
  assign sp_we_eff = l2_ok && sp_we;
  assign spec_p3   = sp_we_eff ? sp_val : f_q.spec;
  // memory speculation (LSU_MEMSPEC): P5 SPD handling, P6 violation check
  lp_ent_ms u_ms (.st4(st4), .wb_go(wb_go), .wb_go_d(wb_go_d), .f_q(f_q), .spec_cur(spec_p3), .head_tag(head_tag), .count_q(count_q),
                  .unk_any(unk_any), .unk_rank(unk_rank), .sa_v(sa_v), .sa_rank(sa_rank), .sa_voff(sa_voff),
                  .sa_f3(sa_f3), .st4v(st4v), .dfr(dfr), .sec4v(sec4v), .vio_n(vio_n), .vio_new(vio_new));
  always_comb begin
    tl_s = '0;
    for (int k = 0; k < NLD; k++) if (tl_tgt[k]) tl_s = tl[k];
    st5 = (|ag_acc) ? LS_PIPE : st4v;
    pipe_r = st_q == LS_PIPE;
    wb3_r = st_q == LS_WB3;
    wbp_r = st_q == LS_WBP;
    vaddr6 = (|ag_acc) ? ag_s.vaddr : f_q.vaddr;
    tl_hit = tl_s.hit;
    tl_pf = tl_s.pf;
    tl_pa = tl_s.paddr;
    mmw_ok = (st_q == LS_MMW) &&
             (rb_hi_valid ? rb_hi_rob_idx == f_q.rob_idx
                                           : rb_head_valid && rb_head_rob_idx == f_q.rob_idx) &&
             ({f_q.snap_flag, f_q.snap_idx} == stq_head_tag) && !unc_busy;
    st6 = mi_pick ? LS_MMR : st5;
  end

  // ---- P10 / P11: allocation, flush ----
  lp_ld_st_t        st7, st8;
  logic [ROBW-1:0]  ridx7;
  logic             rflg7;
  logic             kill;
  logic [EPW-1:0]   epoch_p1;
  assign epoch_p1 = f_q.epoch + EPW'(1);
  always_comb begin
    st7   = al ? LS_ALLOC : st6;
    ridx7 = al ? al_d.rob_idx : f_q.rob_idx;
    rflg7 = al ? al_d.rob_flag : f_q.rob_flag;
    kill  = flush || (mispred && st7 != LS_EMPTY && lp_rob_younger(ridx7, rflg7, dec_rob_idx, dec_rob_flag));
    st8   = kill ? LS_EMPTY : st7;
    dead_r = flush || (mispred && st_q != LS_EMPTY && lp_rob_younger(f_q.rob_idx, f_q.rob_flag, dec_rob_idx, dec_rob_flag));
    epoch_nx = (al || (!dead_r && (|(l1_tgt & l1_launch)))) ? epoch_p1 : f_q.epoch;
  end
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n) !(al && !dead_r && (|(l1_tgt & l1_launch))));
`endif

  // ---- P13 wake-up ----
  lp_ld_st_t     st9;
  logic [2:0]    rc9;
  logic [RWW-1:0] wt9;
  logic [XLEN_BITS-1:0]   res9;
  logic          fill_hit, wake_dc;
  lp_wk_t        wk_e, ew;
  // Event causes of a load parked in this cycle come from the port-level unit; registered causes use registered park info
  logic          w_port;
  assign w_port = park_a;
  lp_wk u_wk (.cause(f_q.rcause), .blk(f_q.blk), .wt(f_q.rwait[lsu_pkg::OW-1:0]),
              .l_voff(f_q.vaddr[11:0]), .l_paddr(f_q.paddr),
              .l_func3(f_q.func3), .ev_sta(ev_sta), .ev_data(ev_data), .ev_ret(ev_ret), .ev_sc(ev_sc),
              .alive_post(alive_post), .sta_info(sta_info), .sdw(sdw), .o(wk_e));
  logic rpw_a;
  logic no_l1_spec_p3, no_l1_spec_p13;
  always_comb begin
    rpw_a = (st3 == LS_RPW) && !dead_r;
    ew = w_port ? l2w : wk_e;
    fill_hit = fill_v && rt3 == RT_MSHR_HIT && fill_line == f_q.paddr[31 -: LINEW];
    wake_dc = fill_hit || (fill_v && rt3 == RT_MSHR_FULL && full_ok);
    full_cand = (st_q == LS_RPW) && !dead_r && (f_q.rcause == 3'(RC_DC)) && fill_v && (f_q.rtype == RT_MSHR_FULL);
    no_l1_spec_p3 = (l2_ok && (l2_dec.act == L2_PARK) && (l2_dec.cause == RC_TLB)) ? 1'b1 :
                    ((rs_ok && !rs_hit && (rs_rep != RT_CONFLICT)) ? 1'b1 : f_q.no_l1_spec);
    no_l1_spec_p13 = (rpw_a && (rc3 == 3'(RC_DC)) && fill_hit) ? 1'b0 : no_l1_spec_p3;
  end

  always_comb begin
    st9 = st8;
    rc9 = rc3;
    wt9 = wt3;
    res9 = res3;
    if (rpw_a) begin
      case (rc3)
        3'(RC_TLB), 3'(RC_DC): begin
          if (rc3 == 3'(RC_DC) && wake_dc) wt9 = '0;
          else if (wt3 != '0) wt9 = wt3 - RWW'(1);
          if (wt9 == '0) st9 = LS_RDY;
        end
        3'(RC_ADDR), 3'(RC_HOLD), 3'(RC_DATA): begin
          if (ew.rdy) st9 = LS_RDY;
          if (ew.wbp) st9 = LS_WBP;
          if (ew.rc_set) rc9 = ew.rc;
          if (ew.wt_set) wt9 = ew.wt;
          if (ew.res_set) res9 = ew.res;
        end
        default: st9 = st8;
      endcase
    end
    rdy9 = (st_q == LS_RDY) && !dead_r;
  end

  // ---- registers ----
  lp_ld_st_t st_d;
  assign st_d = rp_pick ? LS_PIPE : st9;

  always_ff @(posedge clk) begin
    if (!rst_n) st_q <= LS_EMPTY;
    else        st_q <= st_d;
  end

  always_ff @(posedge clk) begin
    f_q.epoch  <= epoch_nx;
    f_q.rcause <= rc9;
    f_q.blk    <= blk3;
    f_q.rwait  <= wt9;
    f_q.rtype  <= rt3;
    f_q.result <= res9;
    f_q.vio    <= vio_n;
    f_q.second <= sec4v;
    if (dfr && wb_go_d) f_q.result <= wb_d_data;
    if (sp_we_eff) f_q.spec <= sp_val;
    if (al) begin
      f_q.vio      <= 1'b0;
      f_q.second   <= 1'b0;
      f_q.spec     <= 1'b0;
      f_q.wait_b   <= al_d.wait_b;
      f_q.mdp      <= al_d.mdp;
      f_q.pc       <= al_d.pc;
      f_q.rob_idx  <= al_d.rob_idx;
      f_q.rob_flag <= al_d.rob_flag;
      f_q.dest_preg <= '0;
      f_q.func3    <= '0;
      f_q.vaddr    <= '0;
      f_q.pa_v     <= 1'b0;
      f_q.paddr    <= '0;
      f_q.mmio     <= 1'b0;
      f_q.pf       <= 1'b0;
      f_q.lrsc     <= 1'b0;
      f_q.result   <= '0;
      f_q.snap_idx <= '0;
      f_q.snap_flag <= 1'b0;
      f_q.rcause   <= '0;
      f_q.blk      <= '0;
      f_q.rwait    <= '0;
      f_q.rtype    <= '0;
      f_q.no_l1_spec <= 1'b0;
    end else begin
      f_q.no_l1_spec <= no_l1_spec_p13;
      if (|ag_acc) begin
        f_q.vaddr    <= ag_s.vaddr;
        f_q.dest_preg <= ag_s.dest;
        f_q.func3    <= ag_s.func3;
        f_q.snap_idx <= ag_s.snap_idx;
        f_q.snap_flag <= ag_s.snap_flag;
        f_q.lrsc     <= ag_s.lr;
        f_q.pa_v     <= 1'b0;
        f_q.paddr    <= '0;
      end
      if (tl_hit) begin
        f_q.pa_v  <= 1'b1;
        f_q.paddr <= tl_pa;
        f_q.mmio  <= tl_s.mmio;
      end
      if (tl_pf) begin
        f_q.pf     <= 1'b1;
        f_q.result <= vaddr6;
      end
    end
  end

endmodule

`default_nettype wire
