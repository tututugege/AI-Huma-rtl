// Ref: back-end/Exu/include/Fu.h  CsrUnit
`default_nettype none

// CSR functional unit: impl_compute is empty (the CSR read data is merged by the Exu at write-back,
// Exu.cpp comb_fu2exu_collect), so only the single-cycle handshake exists.  Spec boundary = the unit itself.
module csr_fu (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic clk,    // wired by the harness wrapper to every module; this FU is purely combinational
  input  logic rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic en,
  input  logic consume,
  output logic complete,
  output logic ready
);

  exu_fu_sc_ctl u_ctl (.en(en), .consume(consume), .complete(complete), .ready(ready));

endmodule

`default_nettype wire
