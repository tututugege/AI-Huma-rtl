// Ref: back-end/Exu/Exu.cpp  Exu::init (MUL instances), back-end/Exu/include/Fu.h  MulUnit
`default_nettype none

// The MUL_NUM multiplier FUs of the Exu, ports flattened as in spec/mul_bank.io.
module mul_bank
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int N = MUL_NUM
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en             [N],
  input  logic                     consume        [N],
  input  logic                     flush          [N],
  input  logic [BR_MASK_WIDTH-1:0] flush_mask     [N],
  input  logic [BR_MASK_WIDTH-1:0] clear_mask     [N],
  input  logic [1:0]               func3          [N],
  input  logic [31:0]              src1_rdata     [N],
  input  logic [31:0]              src2_rdata     [N],
  input  logic [ROB_IDX_WIDTH-1:0] rob_idx        [N],
  input  logic [PRF_IDX_WIDTH-1:0] dest_preg      [N],
  input  logic                     dest_en        [N],
  input  logic [BR_MASK_WIDTH-1:0] br_mask        [N],
  output logic                     complete       [N],
  output logic                     ready          [N],
  output logic [31:0]              result         [N],
  output logic [ROB_IDX_WIDTH-1:0] done_rob_idx   [N],
  output logic [PRF_IDX_WIDTH-1:0] done_dest_preg [N],
  output logic                     done_dest_en   [N],
  output logic [BR_MASK_WIDTH-1:0] done_br_mask   [N]
);

  for (genvar i = 0; i < N; i++) begin : g_mul
    mul_unit u_mul (
      .clk(clk), .rst_n(rst_n), .en(en[i]), .consume(consume[i]), .flush(flush[i]), .flush_mask(flush_mask[i]),
      .clear_mask(clear_mask[i]), .func3(func3[i]), .src1_rdata(src1_rdata[i]), .src2_rdata(src2_rdata[i]),
      .rob_idx(rob_idx[i]), .dest_preg(dest_preg[i]), .dest_en(dest_en[i]), .br_mask(br_mask[i]),
      .complete(complete[i]), .ready(ready[i]), .result(result[i]), .done_rob_idx(done_rob_idx[i]),
      .done_dest_preg(done_dest_preg[i]), .done_dest_en(done_dest_en[i]), .done_br_mask(done_br_mask[i])
    );
  end

endmodule

`default_nettype wire
