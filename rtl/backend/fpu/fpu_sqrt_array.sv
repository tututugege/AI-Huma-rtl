// Ref: back-end/Exu/include/FPU.h  (softfloat f32_sqrt significand root)
`default_nettype none

// Digit-by-digit (restoring) integer square root: root = floor(sqrt(radicand)), 27 result bits, one stage per bit.
// radicand[53:0] in [2^52, 2^54) gives root in [2^26, 2^27). Multi-cycle path like the divider array.
module fpu_sqrt_array (
  input  logic [53:0] radicand,
  output logic [26:0] root,
  output logic        remainder_nonzero
);

  logic [28:0] remainder [28];   // remainder[i+1] after consuming bit pair i (remainder[0] = 0), <= 2*root < 2^28
  logic [26:0] root_part [28];   // root bits decided so far (right aligned)

  assign remainder[0] = 29'd0;
  assign root_part[0] = 27'd0;

  for (genvar i = 0; i < 27; i++) begin : g_stage
    logic [28:0] shifted;        // remainder * 4 + next two radicand bits
    logic [28:0] trial;          // (2*root + 1) * 2 ... classic 4*root+1 trial subtrahend
    logic        fits;
    assign shifted = {remainder[i][26:0], radicand[53-2*i -: 2]};
    assign trial   = {1'b0, root_part[i][25:0], 2'b01};
    assign fits    = (shifted >= trial);
    assign remainder[i+1] = fits ? (shifted - trial) : shifted;
    assign root_part[i+1] = {root_part[i][25:0], fits};
  end

  assign root              = root_part[27];
  assign remainder_nonzero = |remainder[27];

  /* verilator lint_off UNUSEDSIGNAL */  // spare bits of the partial arrays (the remainder never exceeds 2^28)
  logic unused_spare;
  assign unused_spare = ^{remainder[0], root_part[0], remainder[1][28:27], root_part[27][26]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
