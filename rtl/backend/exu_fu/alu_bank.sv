// Ref: back-end/Exu/Exu.cpp  Exu::init (ALU instances), back-end/Exu/include/Fu.h  AluUnit
`default_nettype none

// The ALU_NUM ALU functional units of the Exu, ports flattened as in spec/alu_bank.io.
module alu_bank
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int N = ALU_NUM
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic            clk,    // wired by the harness wrapper to every module; the ALUs are combinational
  input  logic            rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic            en          [N],
  input  logic            consume     [N],
  input  logic [OP_W-1:0] op          [N],
  input  logic [2:0]      func3       [N],
  input  logic [6:0]      func7       [N],
  input  logic            src1_is_pc  [N],
  input  logic            src2_is_imm [N],
  input  logic            is_word [N],
  input  logic [XLEN_BITS-1:0]     pc          [N],
  input  logic [31:0]     imm         [N],
  input  logic [XLEN_BITS-1:0]     src1_rdata  [N],
  input  logic [XLEN_BITS-1:0]     src2_rdata  [N],
  output logic            complete    [N],
  output logic            ready       [N],
  output logic [XLEN_BITS-1:0]     result      [N]
);

  for (genvar i = 0; i < N; i++) begin : g_alu
    alu u_alu (
      .en(en[i]), .consume(consume[i]), .op(op[i]), .func3(func3[i]), .func7(func7[i]),
      .src1_is_pc(src1_is_pc[i]), .src2_is_imm(src2_is_imm[i]), .is_word(is_word[i]), .pc(pc[i]), .imm(imm[i]),
      .src1_rdata(src1_rdata[i]), .src2_rdata(src2_rdata[i]),
      .complete(complete[i]), .ready(ready[i]), .result(result[i])
    );
  end

endmodule

`default_nettype wire
