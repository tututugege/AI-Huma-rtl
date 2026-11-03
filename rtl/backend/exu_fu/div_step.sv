// Ref: back-end/Exu/include/Fu.h  DivUnit::impl_compute (the arithmetic, restructured as an iterative divider)
`default_nettype none

// One restoring-division step on unsigned magnitudes: shift the next dividend bit into the partial remainder and
// subtract the divisor when it fits.  `qd` holds the not-yet-consumed dividend bits at the top and the quotient bits
// produced so far at the bottom (classic shared register).  A zero divisor always "fits", which yields the RISC-V
// results (quotient all ones, remainder = dividend) without a special case.
module div_step (
  input  logic [31:0] rem_in,
  input  logic [31:0] qd_in,
  input  logic [31:0] divisor,
  output logic [31:0] rem_out,
  output logic [31:0] qd_out
);

  logic [32:0] shifted;
  logic        fits;

  always_comb begin
    shifted = {rem_in, qd_in[31]};
    fits    = (shifted >= {1'b0, divisor});
    // shifted < 2**32 whenever it is kept: either shifted < divisor, or the difference is < divisor
    rem_out = fits ? 32'(shifted - {1'b0, divisor}) : shifted[31:0];
    qd_out  = {qd_in[30:0], fits};
  end

endmodule

`default_nettype wire
