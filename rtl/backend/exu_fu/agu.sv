// Ref: back-end/Exu/include/Fu.h  AguUnit
`default_nettype none

// Address generation (load and store-address): vaddr = src1 + sign-extended imm, XLEN bits wide (Sv39 canonical
// checking happens in the TLB / LSU).
module agu import ttg_cfg_pkg::*; (
  input  logic [XLEN_BITS-1:0] src1_rdata,
  input  logic [31:0] imm,
  output logic [XLEN_BITS-1:0] result
);

  always_comb result = src1_rdata + XLEN_BITS'($signed(imm));

endmodule

`default_nettype wire
