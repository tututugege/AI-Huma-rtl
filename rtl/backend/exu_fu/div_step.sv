// Ref: back-end/Exu/include/Fu.h  DivUnit::impl_compute (one restoring-division step)
`default_nettype none

// One restoring step of the XLEN-bit divider: shift the next dividend bit (qd MSB) into the remainder; when the
// remainder reaches the divisor subtract it and shift a 1 into the quotient, else a 0.
module div_step import ttg_cfg_pkg::*; (
  input  logic [XLEN_BITS-1:0] rem_in,
  input  logic [XLEN_BITS-1:0] qd_in,       // dividend bits still to shift in (high) / quotient bits so far (low)
  input  logic [XLEN_BITS-1:0] divisor,
  output logic [XLEN_BITS-1:0] rem_out,
  output logic [XLEN_BITS-1:0] qd_out
);

  logic [XLEN_BITS:0] shifted;
  logic               fits;

  always_comb begin
    shifted = {rem_in, qd_in[XLEN_BITS-1]};
    fits    = (shifted >= {1'b0, divisor});
    rem_out = fits ? XLEN_BITS'(shifted - {1'b0, divisor}) : shifted[XLEN_BITS-1:0];
    qd_out  = {qd_in[XLEN_BITS-2:0], fits};
  end

endmodule

`default_nettype wire
