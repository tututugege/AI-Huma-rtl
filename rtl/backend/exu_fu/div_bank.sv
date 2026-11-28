// Ref: back-end/Exu/Exu.cpp  DivUnit bank
`default_nettype none

module div_bank
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int N = DIV_NUM
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en             [N],
  input  logic                     flush_all      [N],
  input  logic                     flush_br       [N],
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx  [N],
  input  logic                     flush_rob_flag [N],
  input  logic [1:0]               func3          [N],
  input  logic                     is_word        [N],
  input  logic [XLEN_BITS-1:0]     src1_rdata     [N],
  input  logic [XLEN_BITS-1:0]     src2_rdata     [N],
  input  logic [ROB_IDX_WIDTH-1:0] rob_idx        [N],
  input  logic                     rob_flag       [N],
  input  logic [PRF_IDX_WIDTH-1:0] dest_preg      [N],
  input  logic                     dest_en        [N],
  output logic                     complete       [N],
  output logic                     wb_in2         [N],
  output logic                     wake_valid     [N],
  output logic [PRF_IDX_WIDTH-1:0] wake_preg      [N],
  output logic [XLEN_BITS-1:0]     result         [N],
  output logic [ROB_IDX_WIDTH-1:0] done_rob_idx   [N],
  output logic                     done_rob_flag  [N],
  output logic [PRF_IDX_WIDTH-1:0] done_dest_preg [N],
  output logic                     done_dest_en   [N]
);

  for (genvar i = 0; i < N; i++) begin : g_div
    div_unit u_div (
      .clk(clk), .rst_n(rst_n), .en(en[i]),
      .flush_all(flush_all[i]), .flush_br(flush_br[i]),
      .flush_rob_idx(flush_rob_idx[i]), .flush_rob_flag(flush_rob_flag[i]),
      .func3(func3[i]), .is_word(is_word[i]), .src1_rdata(src1_rdata[i]), .src2_rdata(src2_rdata[i]),
      .rob_idx(rob_idx[i]), .rob_flag(rob_flag[i]), .dest_preg(dest_preg[i]), .dest_en(dest_en[i]),
      .complete(complete[i]),
      .wb_in2(wb_in2[i]), .wake_valid(wake_valid[i]), .wake_preg(wake_preg[i]),
      .result(result[i]),
      .done_rob_idx(done_rob_idx[i]), .done_rob_flag(done_rob_flag[i]),
      .done_dest_preg(done_dest_preg[i]), .done_dest_en(done_dest_en[i])
    );
  end

endmodule

`default_nettype wire
