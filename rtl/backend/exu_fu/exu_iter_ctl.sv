// Ref: back-end/Exu/include/AbstractFU.h  IterativeFU (busy / done_cycle / comb_ctrl / comb_issue / comb_consume)
`default_nettype none

module exu_iter_ctl
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int CW = 4
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  input  logic                     en,
  input  logic [CW-1:0]            lat_m1,
  input  logic [ROB_IDX_WIDTH-1:0] en_rob_idx,
  input  logic                     en_rob_flag,
  output logic                     accept,
  output logic                     run,
  output logic                     complete,
  output logic                     wb_next,
  output logic                     wb_in2,
  output logic                     done_rob_flag
);

  logic                     busy_q, busy_d;
  logic [CW-1:0]            cnt_q, cnt_d;
  logic [ROB_IDX_WIDTH-1:0] rob_idx_q, rob_idx_d;
  logic                     rob_flag_q, rob_flag_d;

  logic kill, live, finished;

  always_comb begin
    kill          = busy_q && (flush_all || (flush_br && fu_rob_younger(rob_idx_q, rob_flag_q, flush_rob_idx, flush_rob_flag)));
    live          = busy_q && !kill;
    finished      = (cnt_q == '0);
    complete      = live && finished;
    wb_next       = live && (cnt_q == CW'(1));
    accept        = en && !live;
    wb_in2        = (accept && (lat_m1 == CW'(1))) || (live && (cnt_q == CW'(2)));
    run           = live && !finished;
    done_rob_flag = rob_flag_q;

    busy_d     = accept || run;
    cnt_d      = accept ? lat_m1 : (finished ? '0 : cnt_q - CW'(1));
    rob_idx_d  = accept ? en_rob_idx  : rob_idx_q;
    rob_flag_d = accept ? en_rob_flag : rob_flag_q;
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && en && live) $error("exu_iter_ctl: re-entered while busy");
`endif

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy_q     <= 1'b0;
      cnt_q      <= '0;
      rob_idx_q  <= '0;
      rob_flag_q <= 1'b0;
    end else begin
      busy_q     <= busy_d;
      cnt_q      <= cnt_d;
      rob_idx_q  <= rob_idx_d;
      rob_flag_q <= rob_flag_d;
    end
  end

endmodule

`default_nettype wire
