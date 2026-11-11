// Ref: back-end/Exu/include/Fu.h  AguUnit
`default_nettype none

// Address generation (load and store-address): vaddr = src1 + imm, truncated to 32 bits (the C++ adds in 64 bits and
// stores into a 32-bit result).
module agu import ttg_cfg_pkg::*; (
  input  logic        en,
  input  logic        consume,
  input  logic [XLEN_BITS-1:0] src1_rdata,
  input  logic [31:0] imm,
  output logic        complete,
  output logic        ready,
  output logic [XLEN_BITS-1:0] result
);

  exu_fu_sc_ctl u_ctl (.en(en), .consume(consume), .complete(complete), .ready(ready));

  always_comb result = src1_rdata + XLEN_BITS'($signed(imm));

endmodule

`default_nettype wire
