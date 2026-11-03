// Ref: back-end/Exu/Exu.cpp  Exu::init (SDU instances), back-end/Exu/include/Fu.h  SduUnit
`default_nettype none

// The LSU_SDU_COUNT store-data units, ports flattened as in spec/sdu_bank.io.
module sdu_bank
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int N = LSU_SDU_COUNT
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic             clk,    // wired by the harness wrapper to every module; the SDUs are combinational
  input  logic             rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic             en         [N],
  input  logic             consume    [N],
  input  logic             is_atomic  [N],
  input  logic [AMO_W-1:0] amo_op     [N],
  input  logic [31:0]      src1_rdata [N],
  input  logic [31:0]      src2_rdata [N],
  output logic             complete   [N],
  output logic             ready      [N],
  output logic [31:0]      result     [N]
);

  for (genvar i = 0; i < N; i++) begin : g_sdu
    sdu u_sdu (
      .en(en[i]), .consume(consume[i]), .is_atomic(is_atomic[i]), .amo_op(amo_op[i]),
      .src1_rdata(src1_rdata[i]), .src2_rdata(src2_rdata[i]),
      .complete(complete[i]), .ready(ready[i]), .result(result[i])
    );
  end

endmodule

`default_nettype wire
