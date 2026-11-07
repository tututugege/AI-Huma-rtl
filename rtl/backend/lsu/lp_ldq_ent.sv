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
  input  logic [BRW-1:0]      dec_br_mask,
  input  logic [BRW-1:0]      clear_mask,
  // P2 MMIO response
  input  logic                mm_go,
  input  logic [31:0]         mm_data,
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
  input  logic [31:0]         rs_raw,
  input  logic                rs_busy,             // the response port already carries an L2 write-back
  output logic                rs_ok,
  // P5 write-back
  input  logic                wb_go,
  output logic                st3_wbp,
  output logic [31:0]         res_v,               // result as seen by the write-back (after P2 / P3)
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
  output logic                pipe5,               // state PIPE after the AGU arrival (replay register check)
  output logic                dead_r,              // killed by this cycle's flush / mispredict (registered fields only)
  output logic                empty8,              // killed / free after the flush step
  output logic                pipe8,
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
        L2_WBD:  st2 = ((LP_L2 & 1) != 0) ? LS_WB3 : st1;
        default: st2 = st1;
      endcase
    end
    rs_ok = rs_v && st2 == LS_DCW && f_q.epoch == rs_ep;
    park_b = rs_ok && !rs_hit;
    st3 = st2;
    if (rs_ok && rs_hit && rs_busy) st3 = LS_WBP;
    else if (rs_ok && rs_hit && ((LP_L2 & 1) != 0)) st3 = LS_WB3;
    if (park_b) st3 = LS_RPW;
    st3_wbp = st3 == LS_WBP;
  end

  // ---- fields after P3 (park information, rtype) ----
  logic [2:0]     rc3;
  logic [SQW-1:0] blk3;
  logic [RWW-1:0] wt3;
  logic [1:0]     rt3;
  logic [31:0]    res3;
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
    if (rs_ok && rs_hit && rs_busy) res3 = lsu_pkg::extract_data(rs_raw, f_q.paddr[1:0], f_q.func3);
    if (park_b) begin
      rc3 = 3'(RC_DC);
      blk3 = '0;
      wt3 = replay_wait(rs_rep);
    end
    res_v = res3;
  end

  // ---- P5 .. P9: write-back frees, AGU arrival, DTLB result, MMIO issue ----
  lp_ld_st_t st4, st5, st6;
  logic      tl_hit, tl_pf;
  logic [31:0] tl_pa, vaddr6;
  lp_tl_t    tl_s;
  always_comb begin
    tl_s = '0;
    for (int k = 0; k < NLD; k++) if (tl_tgt[k]) tl_s = tl[k];
    st4 = wb_go ? LS_EMPTY : st3;
    st5 = (|ag_acc) ? LS_PIPE : st4;
    pipe5 = st5 == LS_PIPE;
    pipe_r = st_q == LS_PIPE;
    wb3_r = st_q == LS_WB3;
    wbp_r = st_q == LS_WBP;
    vaddr6 = (|ag_acc) ? ag_s.vaddr : f_q.vaddr;
    tl_hit = tl_s.hit;
    tl_pf = tl_s.pf;
    tl_pa = tl_s.paddr;
    // LP_CUT[10]: an MMW entry is never written back or re-armed in P5/P6, so the registered-side state st3 decides
    // LP_L2[5]: only entries that were already MMW at the start of the cycle are issued
    mmw_ok = (((LP_L2 & 32) != 0) ? st_q == LS_MMW : (((LP_CUT & 1024) != 0) ? st3 == LS_MMW : st5 == LS_MMW)) &&
             (rb_hi_valid ? rb_hi_rob_idx == f_q.rob_idx
                                           : rb_head_valid && rb_head_rob_idx == f_q.rob_idx) &&
             ({f_q.snap_flag, f_q.snap_idx} == stq_head_tag) && !unc_busy;
    st6 = mi_pick ? LS_MMR : st5;
  end

  // ---- P10 / P11: allocation, flush ----
  lp_ld_st_t   st7, st8;
  logic [BRW-1:0] br7;
  logic        kill;
  always_comb begin
    st7 = al ? LS_ALLOC : st6;
    br7 = al ? al_d.br_mask : f_q.br_mask;
    kill = flush || (mispred && st7 != LS_EMPTY && (br7 & dec_br_mask) != '0);
    st8 = kill ? LS_EMPTY : st7;
    empty8 = st8 == LS_EMPTY;
    dead_r = flush || (mispred && st_q != LS_EMPTY && (f_q.br_mask & dec_br_mask) != '0);
    pipe8 = st8 == LS_PIPE;
    // LP_CUT[16]: an entry targeted by an L1 slot is in PIPE; only the flush kill can change that
    epoch_nx = f_q.epoch + EPW'(al) +
               EPW'((((LP_CUT & 65536) != 0) ? !dead_r : pipe8) && (|(l1_tgt & l1_launch)));
  end

  // ---- P13 wake-up ----
  lp_ld_st_t     st9;
  logic [2:0]    rc9;
  logic [RWW-1:0] wt9;
  logic [31:0]   res9;
  logic          fill_hit, wake_dc;
  lp_wk_t        wk_e, ew;
  // LP_L2[8]: the event causes of a load parked in this cycle come from the port-level unit (no L2 decision in front of
  // the confirm); the registered causes use the registered park information
  logic          w_port;
  assign w_port = ((LP_L2 & 256) != 0) && park_a;
  lp_wk u_wk (.cause(((LP_L2 & 256) != 0) ? f_q.rcause : rc3), .blk(((LP_L2 & 256) != 0) ? f_q.blk : blk3),
              .wt(((LP_L2 & 256) != 0) ? f_q.rwait[1:0] : wt3[1:0]), .l_voff(f_q.vaddr[11:0]), .l_paddr(f_q.paddr),
              .l_func3(f_q.func3), .ev_sta(ev_sta), .ev_data(ev_data), .ev_ret(ev_ret), .ev_sc(ev_sc),
              .alive_post(alive_post), .sta_info(sta_info), .sdw(sdw), .o(wk_e));
  // LP_CUT[11]: the wake-up acts on entries that were parked before the flush step; st3 + the flush kill decide this
  logic rpw_a;
  always_comb begin
    rpw_a = ((LP_CUT & 2048) != 0) ? (st3 == LS_RPW && !dead_r) : (st8 == LS_RPW);
    ew = w_port ? l2w : wk_e;
    fill_hit = fill_v && rt3 == RT_MSHR_HIT && fill_line == f_q.paddr[31 -: LINEW];
    wake_dc = fill_hit || (fill_v && rt3 == RT_MSHR_FULL && full_ok);
    // LP_L2[4]: only loads parked at the start of the cycle compete for the MSHR-FULL wake-up (a load that gets
    // MSHR_FULL in this very cycle waits for its counter)
    if ((LP_L2 & 16) != 0)
      full_cand = st_q == LS_RPW && !dead_r && f_q.rcause == 3'(RC_DC) && fill_v && f_q.rtype == RT_MSHR_FULL;
    else
      full_cand = rpw_a && rc3 == 3'(RC_DC) && fill_v && rt3 == RT_MSHR_FULL;
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
    // LP_CUT[2]: only RDY bits registered at the cycle start
    rdy9 = ((LP_CUT & 4) != 0) ? (st_q == LS_RDY && !(((LP_CUT & 128) != 0) ? dead_r : kill)) : (st9 == LS_RDY);
  end

  // ---- registers ----
  lp_ld_st_t st_d;
  assign st_d = rp_pick ? LS_PIPE : st9;

  always_ff @(posedge clk) begin
    if (!rst_n) st_q <= LS_EMPTY;
    else        st_q <= st_d;
  end

  logic [BRW-1:0] br_d;
  assign br_d = al ? al_d.br_mask : (st_q != LS_EMPTY ? f_q.br_mask & ~clear_mask : f_q.br_mask);

  always_ff @(posedge clk) begin
    f_q.epoch  <= epoch_nx;
    f_q.br_mask <= br_d;
    f_q.rcause <= rc9;
    f_q.blk    <= blk3;
    f_q.rwait  <= wt9;
    f_q.rtype  <= rt3;
    f_q.result <= res9;
    if (al) begin
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
    end else begin
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
