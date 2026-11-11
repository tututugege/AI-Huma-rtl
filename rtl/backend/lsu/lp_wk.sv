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
  /* verilator lint_off UNUSEDSIGNAL */
  lp_sta_info_t  inf;
  /* verilator lint_on UNUSEDSIGNAL */
  lp_conf_t      conf;
  logic [lsu_pkg::OW-1:0] off_a;
  logic [XLEN_BITS-1:0]   std_d;
  always_comb begin
    b_sta = ev_sta[blk];
    b_ret = ev_ret[blk];
    b_sc = ev_sc[blk];
    b_data = ev_data[blk];
    alive_b = alive_post[blk] && !b_ret;
    inf = '0;
    std_d = '0;
    for (int k = 0; k < NST; k++) if (sta_info[k].v && sta_info[k].stq == blk) inf = sta_info[k];
    for (int k = 0; k < NSD; k++) if (sdw[k].v && sdw[k].stq == blk) std_d = sdw[k].data;
    conf = stlf_confirm(l_voff, l_paddr, l_func3, alive_b, inf.suppress, inf.va_v, inf.voff, inf.pa_v, inf.paddr,
                        inf.func3, inf.data_v, inf.hold_sc);
    off_a = l_paddr[lsu_pkg::OW-1:0] - inf.paddr[lsu_pkg::OW-1:0];
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
              o.res = lsu_pkg::extract_data(inf.data, off_a, l_func3);
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
