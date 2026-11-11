// Ref: back-end/Exu/include/Fu.h  AluUnit shifter (sll/srl/sra/rol/ror, XLEN wide)
`default_nettype none

// Funnel shifter: right shift of {fill, x} by shamt; a left shift / rotate runs it around two bit-reversals.
// A rotate fills with x itself, an arithmetic shift with the sign, a logical shift with zeros.  The caller applies the
// rv64 word-op operand preconditioning (zero/sign extension, {a, a} for rotates).
module alu_shift import ttg_cfg_pkg::*; (
  input  logic [XLEN_BITS-1:0]         x,
  input  logic [$clog2(XLEN_BITS)-1:0] shamt,
  input  logic                         left,
  input  logic                         rot,
  input  logic                         arith,
  output logic [XLEN_BITS-1:0]         y
);

  logic [XLEN_BITS-1:0]   x_dir, y_dir, fill;
  logic [2*XLEN_BITS-1:0] wide;

  always_comb begin
    for (int i = 0; i < XLEN_BITS; i++) x_dir[i] = left ? x[XLEN_BITS - 1 - i] : x[i];
    fill    = rot ? x_dir : {XLEN_BITS{arith && x[XLEN_BITS-1]}};
    wide    = {fill, x_dir};
    y_dir   = XLEN_BITS'(wide >> shamt);
    for (int i = 0; i < XLEN_BITS; i++) y[i] = left ? y_dir[XLEN_BITS - 1 - i] : y_dir[i];
  end

endmodule

`default_nettype wire
