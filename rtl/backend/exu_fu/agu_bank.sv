// Ref: back-end/Exu/Exu.cpp  Exu::init (AGU instances), back-end/Exu/include/Fu.h  AguUnit
`default_nettype none

// The LSU_AGU_COUNT address-generation units (load AGUs first, then store-address AGUs), ports flattened as in
// spec/agu_bank.io.
module agu_bank
  import ttg_cfg_pkg::*;
#(
  parameter int N = LSU_AGU_COUNT
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,    // wired by the harness wrapper to every module; the AGUs are combinational
  input  logic        rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        en         [N],
  input  logic        consume    [N],
  input  logic [XLEN_BITS-1:0] src1_rdata [N],
  input  logic [31:0] imm        [N],
  output logic        complete   [N],
  output logic        ready      [N],
  output logic [XLEN_BITS-1:0] result     [N]
);

  for (genvar i = 0; i < N; i++) begin : g_agu
    agu u_agu (
      .en(en[i]), .consume(consume[i]), .src1_rdata(src1_rdata[i]), .imm(imm[i]),
      .complete(complete[i]), .ready(ready[i]), .result(result[i])
    );
  end

endmodule

`default_nettype wire
