// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_check_p wake-up pass: RC_ADDR / RC_HOLD / RC_DATA)
`default_nettype none

// Wake-up of one parked load on the blocking store `blk`: the events of this cycle (STA arrival / retire / SC verdict /
// STD write) decide whether the load moves to RDY or WBP or changes its park cause.  The STLF confirm uses the
// broadcast view of the STQ entry (sta_info) and the STD data (sdw).  Used per LDQ entry (registered park information)
// and, with LP_L2[8], per load port for the load that parks in this very cycle.
module lp_wk
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic [2:0]          cause,
  input  logic [SQW-1:0]      blk,
  input  logic [lsu_pkg::OW-1:0] wt,         // RC_DATA: byte offset of the load inside the store data
  input  logic [11:0]         l_voff,
  input  logic [31:0]         l_paddr,
  input  logic [2:0]          l_func3,
  input  logic [SQ-1:0]       ev_sta,
  input  logic [SQ-1:0]       ev_data,
  input  logic [SQ-1:0]       ev_ret,
  input  logic [SQ-1:0]       ev_sc,
  input  logic [SQ-1:0]       alive_post,
  input  lp_sta_info_t        sta_info [NST],
  input  lp_std_t             sdw [NSD],
  output lp_wk_t              o
);

  logic          b_sta, b_ret, b_sc, b_data, alive_b;
  /* verilator lint_off UNUSEDSIGNAL */  // v / stq already consumed by the match select
  lp_sta_info_t  sel_sta;
  /* verilator lint_on UNUSEDSIGNAL */
  lp_conf_t      conf;
  logic [lsu_pkg::OW-1:0] off_a;
  logic [XLEN_BITS-1:0]   inf_data, std_d;
  always_comb begin
    b_sta = ev_sta[blk];
    b_ret = ev_ret[blk];
    b_sc = ev_sc[blk];
    b_data = ev_data[blk];
    alive_b = alive_post[blk] && !b_ret;
    // Mux the single matching STA broadcast view first (1 copy of stlf_confirm_pre_s per LDQ entry, zero 29b adders!)
    sel_sta = '0;
    for (int k = 0; k < NST; k++) begin
      if (sta_info[k].v && (sta_info[k].stq == blk)) sel_sta = sta_info[k];
    end
    conf     = stlf_confirm_pre_s(l_voff, l_paddr, l_func3, alive_b, sel_sta.suppress, sel_sta.va_v,
                                  sel_sta.voff, sel_sta.pa_v, sel_sta.paddr, sel_sta.paddr_p1, sel_sta.paddr_m1,
                                  sel_sta.func3, sel_sta.data_v, sel_sta.hold_sc);
    off_a    = l_paddr[lsu_pkg::OW-1:0] - sel_sta.paddr[lsu_pkg::OW-1:0];
    inf_data = sel_sta.data;
    std_d = '0;
    for (int k = 0; k < NSD; k++) if (sdw[k].v && sdw[k].stq == blk) std_d = sdw[k].data;
  end

  always_comb begin
    o = '0;
    case (cause)
      3'(RC_ADDR): begin
        if (b_sta || b_ret) begin
          case (conf)
            CF_REPLAY: o.rdy = 1'b1;
            CF_HOLD: begin
              o.rc_set = 1'b1;
              o.rc = 3'(RC_HOLD);
            end
            CF_DATA: begin
              o.rc_set = 1'b1;
              o.rc = 3'(RC_DATA);
              o.wt_set = 1'b1;
              o.wt = RWW'(off_a);
            end
            CF_FWD: begin
              o.wbp = 1'b1;
              o.res_set = 1'b1;
              o.res = lsu_pkg::extract_data(inf_data, off_a, l_func3);
            end
            default: ;
          endcase
        end
      end
      3'(RC_HOLD): if (b_ret || b_sc) o.rdy = 1'b1;
      3'(RC_DATA): begin
        if (b_data) begin
          o.wbp = 1'b1;
          o.res_set = 1'b1;
          o.res = lsu_pkg::extract_data(std_d, wt, l_func3);
        end else if (b_ret) begin
          o.rdy = 1'b1;
        end
      end
      default: ;
    endcase
  end

endmodule

`default_nettype wire
