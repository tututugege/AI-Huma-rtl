// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (PStq: staged STQ entry; comb_*_p phases applied in the BackTop order)
`default_nettype none

// One STQ entry of the staged LSU (events decoded by the glue, applied in the model's phase order):
//   P1 commit, P2 MMIO response, P4 DCache store response + fill wake, P5 STA / SC write-back, P6 STD + STA arrival,
//   P8 DTLB result, P10 allocation, P11 clear_mask, P13 drain, P14 STA replay register.
module lp_stq_ent
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
#(
  parameter int IDX = 0
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                rb_flush,
  input  logic [BRW-1:0]      clear_mask,
  input  logic                alive_w,           // inside [head, head + count) at the start of the cycle
  // P1 commit
  input  logic                cm_go,
  // P2 MMIO store response
  input  logic                mm_done,
  // P4 DCache store response, MSHR fill wake
  input  logic                rsp_v,
  input  logic [1:0]          rsp_rep,
  input  logic                win4,              // rank < min(ccount, count)
  input  logic                fill_v,
  input  logic [LINEW-1:0]    fill_line,
  input  logic                full_ok,
  output logic                full_cand,
  // P5 write-back
  input  logic                wb_go,
  input  logic                sc_go,             // an SC (not faulting) is written back: verdict from the reservation
  input  logic                rsv_valid,
  input  logic [31:0]         rsv_addr,
  // P6 STD / STA
  input  lp_std_t             sdw [NSD],
  input  lp_agu_st_t          sta [NST],
  output logic                sd_acc,
  output logic [NST-1:0]      sa_acc,
  // P8 DTLB result of the STA slots
  input  logic [NST-1:0]      tl_tgt,
  input  logic [NST-1:0]      tl_miss,
  input  lp_tl_t              tl [NST],
  // P10 allocation
  input  logic                al_v,
  /* verilator lint_off UNUSEDSIGNAL */  // only some fields are used
  input  lp_dis_st_t          al_d,
  /* verilator lint_on UNUSEDSIGNAL */
  // P13 drain
  input  logic                win13,             // rank < min(ccount, count) at drain time
  input  logic                dr_pick,
  input  logic                dr_mmio,
  output logic                d_elig,
  output logic                d_rdy,
  // P14
  input  logic                srp_take,
  // views
  output lp_stq_t             q_o,
  output logic                cv_va,             // CAM view: STA bypass included (after P6)
  output logic [11:0]         cv_voff,
  output logic [2:0]          cv_f3,
  output lp_sta_info_t        vw,                // broadcast view with an STA event (after P8)
  output logic                done_v,            // done as seen by the retire scan
  output logic                trp_v              // STA DTLB retry pending (after P8)
);

  lp_stq_t ent_q;
  assign q_o = ent_q;

  // ---- P1 .. P5 ----
  logic cmt1, sup1, done1, mmw2, done2, rsp_ok, iss4, done4, done4n;
  logic [1:0] rt4;
  logic [RWW-1:0] rw4, rw5;
  logic [RWW-1:1] rw5g;
  logic fl_cand, hit_wake, wbp5, wbd5, pass5, sc_pass5, sup5;
  always_comb begin
    cmt1 = ent_q.cmt | cm_go;
    sup1 = ent_q.suppress | (cm_go && (rb_flush || (ent_q.lrsc && !ent_q.sc_pass)));
    done1 = ent_q.done | (cm_go && (rb_flush || (ent_q.lrsc && !ent_q.sc_pass)));
    mmw2 = ent_q.mmw & !mm_done;
    done2 = done1 | (mm_done & ent_q.mmw);
    rsp_ok = rsp_v && ent_q.iss;
    iss4 = ent_q.iss & !rsp_ok;
    rt4 = rsp_ok ? rsp_rep : ent_q.rtype;
    done4 = done2 | (rsp_ok && rsp_rep == RT_HIT);
    done4n = ent_q.done | (mm_done & ent_q.mmw) | (rsp_ok && rsp_rep == RT_HIT);   // without this cycle's commit
    rw4 = rsp_ok ? ((rsp_rep == RT_HIT) ? RWW'(0) : replay_wait(rsp_rep)) : ent_q.rwait;
    // LP_CUT[9]: a store committed in this cycle has no replay wait yet
    fl_cand = fill_v && win4 && !iss4 && rw4 != '0 &&
              (((LP_CUT & 512) != 0) ? (ent_q.cmt && !done4n) : (cmt1 && !done4));
    full_cand = fl_cand && rt4 == RT_MSHR_FULL;
    hit_wake = fl_cand && rt4 == RT_MSHR_HIT && fill_line == ent_q.paddr[31 -: LINEW];
    rw5 = (hit_wake || (full_cand && full_ok)) ? RWW'(0) : rw4;
    rw5g = hit_wake ? '0 : rw4[RWW-1:1];   // LP_CUT[4]: the drain does not see the MSHR-full wake of this cycle
    wbp5 = ent_q.wbp & !wb_go;
    wbd5 = ent_q.wbd | wb_go;
    pass5 = rsv_valid && rsv_addr == ent_q.paddr;
    sc_pass5 = sc_go ? pass5 : ent_q.sc_pass;
    sup5 = sc_go ? !pass5 : sup1;
  end

  // ---- P6 STD / STA arrival, P8 DTLB ----
  logic [NSD-1:0] sd_hit;
  logic [NST-1:0] sa_hit;
  /* verilator lint_off UNUSEDSIGNAL */  // only the fields used by this entry are read
  lp_std_t std_s;
  lp_agu_st_t sta_s;
  /* verilator lint_on UNUSEDSIGNAL */
  lp_tl_t tl_s;
  logic tl_any, tl_m, data_v6, wbp6, va6, pa6, pa8, trp8, wbp8, pf8, sa_any;
  logic [31:0] vaddr6, paddr6, paddr8, data6;
  logic [2:0] f3_6;
  logic lrsc6, mmio8;
  always_comb begin
    std_s = '0;
    sta_s = '0;
    tl_s = '0;
    tl_any = 1'b0;
    tl_m = 1'b0;
    for (int k = 0; k < NSD; k++) begin
      sd_hit[k] = sdw[k].v && sdw[k].stq == SQW'(IDX) && sdw[k].rob_idx == ent_q.rob_idx &&
                  sdw[k].rob_flag == ent_q.rob_flag;
      if (sd_hit[k]) std_s = sdw[k];
    end
    for (int k = 0; k < NST; k++) begin
      sa_hit[k] = sta[k].v && sta[k].stq == SQW'(IDX) && sta[k].rob_idx == ent_q.rob_idx &&
                  sta[k].rob_flag == ent_q.rob_flag;
      if (sa_hit[k]) sta_s = sta[k];
      if (tl_tgt[k]) begin
        tl_s = tl[k];
        tl_any = 1'b1;
        tl_m = tl_miss[k];
      end
    end
    sd_acc = |sd_hit;
    sa_acc = sa_hit;
    sa_any = |sa_hit;
  end

  always_comb begin
    data_v6 = ent_q.data_v | sd_acc;
    data6 = sd_acc ? std_s.data : ent_q.data;
    wbp6 = wbp5 | (sd_acc && ent_q.pa_v && !wbp5 && !wbd5);
    va6 = ent_q.va_v | sa_any;
    vaddr6 = sa_any ? sta_s.vaddr : ent_q.vaddr;
    f3_6 = sa_any ? sta_s.func3 : ent_q.func3;
    lrsc6 = sa_any ? sta_s.sc : ent_q.lrsc;
    pa6 = sa_any ? 1'b0 : ent_q.pa_v;
    paddr6 = sa_any ? 32'd0 : ent_q.paddr;
    trp8 = sa_any ? 1'b0 : ent_q.trp;
    pa8 = pa6;
    paddr8 = paddr6;
    wbp8 = wbp6;
    pf8 = ent_q.pf;
    mmio8 = ent_q.mmio;
    if (tl_any && tl_m) trp8 = 1'b1;
    if (tl_any && tl_s.hit) begin
      pa8 = 1'b1;
      paddr8 = tl_s.paddr;
      mmio8 = tl_s.mmio;
      if (data_v6 && !wbp6 && !wbd5) wbp8 = 1'b1;
    end
    if (tl_any && tl_s.pf) begin
      pf8 = 1'b1;
      if (!wbp6 && !wbd5) wbp8 = 1'b1;
    end
  end

  assign cv_va = va6;
  assign cv_voff = vaddr6[11:0];
  assign cv_f3 = f3_6;
  always_comb begin
    vw = '0;
    vw.va_v = va6;
    vw.voff = vaddr6[11:0];
    vw.func3 = f3_6;
    vw.pa_v = pa8;
    vw.paddr = paddr8;
    vw.data_v = data_v6;
    vw.hold_sc = lrsc6 && !sc_pass5;
    vw.suppress = sup5;
    vw.data = data6;
  end

  // ---- P13 drain view ----
  logic rw_dec;
  logic [RWW-1:0] rw13;
  always_comb begin
    d_elig = win13 && (((LP_CUT & 8192) != 0) ? (ent_q.cmt && !done4n) : (cmt1 && !done4)) && !ent_q.iss && !mmw2;
    d_rdy = d_elig && (((LP_CUT & 16) != 0) ? rw5g == '0 : rw5[RWW-1:1] == '0);
    rw_dec = d_elig && rw5 != '0;
    rw13 = rw_dec ? rw5 - RWW'(1) : rw5;
    done_v = done4;
    trp_v = trp8;
  end

  // ---- registers ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ent_q.cmt <= 1'b0;
      ent_q.done <= 1'b0;
      ent_q.wbp <= 1'b0;
      ent_q.wbd <= 1'b0;
      ent_q.iss <= 1'b0;
      ent_q.mmw <= 1'b0;
      ent_q.trp <= 1'b0;
    end else if (al_v) begin
      ent_q.cmt <= 1'b0;
      ent_q.done <= 1'b0;
      ent_q.wbp <= 1'b0;
      ent_q.wbd <= 1'b0;
      ent_q.iss <= 1'b0;
      ent_q.mmw <= 1'b0;
      ent_q.trp <= 1'b0;
    end else begin
      ent_q.cmt <= cmt1;
      ent_q.done <= done4;
      ent_q.wbp <= wbp8;
      ent_q.wbd <= wbd5;
      ent_q.iss <= iss4 | dr_pick;
      ent_q.mmw <= mmw2 | dr_mmio;
      ent_q.trp <= trp8 & !srp_take;
    end
  end

  always_ff @(posedge clk) begin
    if (al_v) begin
      ent_q.va_v <= 1'b0;
      ent_q.pa_v <= 1'b0;
      ent_q.data_v <= 1'b0;
      ent_q.pf <= 1'b0;
      ent_q.mmio <= 1'b0;
      ent_q.lrsc <= 1'b0;
      ent_q.sc_pass <= 1'b0;
      ent_q.suppress <= 1'b0;
      ent_q.vaddr <= '0;
      ent_q.paddr <= '0;
      ent_q.data <= '0;
      ent_q.func3 <= al_d.func3;
      ent_q.dest_preg <= '0;
      ent_q.rob_idx <= al_d.rob_idx;
      ent_q.rob_flag <= al_d.rob_flag;
      ent_q.br_mask <= al_d.br_mask;
      ent_q.rtype <= '0;
      ent_q.rwait <= '0;
    end else begin
      ent_q.va_v <= va6;
      ent_q.pa_v <= pa8;
      ent_q.data_v <= data_v6;
      ent_q.pf <= pf8;
      ent_q.mmio <= mmio8;
      ent_q.lrsc <= lrsc6;
      ent_q.sc_pass <= sc_pass5;
      ent_q.suppress <= sup5;
      ent_q.vaddr <= vaddr6;
      ent_q.paddr <= paddr8;
      ent_q.data <= data6;
      ent_q.func3 <= f3_6;
      if (sa_any) ent_q.dest_preg <= sta_s.dest;
      if (alive_w) ent_q.br_mask <= ent_q.br_mask & ~clear_mask;
      ent_q.rtype <= rt4;
      ent_q.rwait <= dr_pick ? rw13 : rw13;
    end
  end

endmodule

`default_nettype wire
