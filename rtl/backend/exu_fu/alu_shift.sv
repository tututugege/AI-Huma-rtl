// Ref: back-end/Exu/include/Fu.h  AluUnit::impl_compute (sll/srl/sra/rol/ror)
`default_nettype none

// One 64->32 funnel shifter serves all shifts and rotates: right shifts feed {fill, x}, rotates feed {x, x}, and the
// left variants run the same datapath on the bit-reversed operand (rotl = rev(rotr(rev x)), sll = rev(srl(rev x))).
// Rotate by 0 returns x (the C++ `x >> (32 - 0)` is undefined behaviour; see docs/modules/exu_int.md, D-EXU-1).
module alu_shift (
  input  logic [31:0] x,
  input  logic [4:0]  shamt,
  input  logic        left,
  input  logic        rot,
  input  logic        arith,
  output logic [31:0] y
);

  logic [31:0] x_dir, y_dir, fill;
  logic [63:0] wide;

  always_comb begin
    for (int i = 0; i < 32; i++) x_dir[i] = left ? x[31 - i] : x[i];
    fill    = rot ? x_dir : {32{arith && x[31]}};
    wide    = {fill, x_dir};
    y_dir   = 32'(wide >> shamt);
    for (int i = 0; i < 32; i++) y[i] = left ? y_dir[31 - i] : y_dir[i];
  end

endmodule

`default_nettype wire
