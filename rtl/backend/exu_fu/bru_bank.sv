// Ref: back-end/Exu/Exu.cpp  Exu::init (BRU instances), back-end/Exu/include/Fu.h  BruUnit
`default_nettype none

// The BRU_NUM branch units of the Exu, ports flattened (combinational).
module bru_bank
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int N = BRU_NUM
) (
  input  logic [OP_W-1:0] op             [N],
  input  logic [2:0]      func3          [N],
  input  logic            src1_en        [N],
  input  logic [XLEN_BITS-1:0]     src1_rdata     [N],
  input  logic [XLEN_BITS-1:0]     src2_rdata     [N],
  input  logic [XLEN_BITS-1:0]     pc             [N],
  input  logic [31:0]     imm            [N],
  input  logic            ftq_pred_taken [N],
  input  logic            ftq_is_rvc [N],
  input  logic [XLEN_BITS-1:0]     ftq_next_pc    [N],
  output logic            br_taken       [N],
  output logic            mispred        [N],
  output logic [XLEN_BITS-1:0]     diag_val       [N]
);

  for (genvar i = 0; i < N; i++) begin : g_bru
    bru u_bru (
      .op(op[i]), .func3(func3[i]), .src1_en(src1_en[i]),
      .src1_rdata(src1_rdata[i]), .src2_rdata(src2_rdata[i]), .pc(pc[i]), .imm(imm[i]),
      .ftq_pred_taken(ftq_pred_taken[i]), .ftq_is_rvc(ftq_is_rvc[i]), .ftq_next_pc(ftq_next_pc[i]),
      .br_taken(br_taken[i]), .mispred(mispred[i]), .diag_val(diag_val[i])
    );
  end

endmodule

`default_nettype wire
