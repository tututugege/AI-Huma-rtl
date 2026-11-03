// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FSGNJ: fsgnj / fsgnjn / fsgnjx)
`default_nettype none

// Sign injection: magnitude of a, sign from b (copied, inverted, xor-ed with a's). NaNs pass through unmodified.
module fpu_sgnj (
  input  logic [31:0] a,
  input  logic        b_sign,
  output logic [31:0] sgnj,
  output logic [31:0] sgnjn,
  output logic [31:0] sgnjx
);

  assign sgnj  = {b_sign, a[30:0]};
  assign sgnjn = {~b_sign, a[30:0]};
  assign sgnjx = {a[31] ^ b_sign, a[30:0]};

endmodule

`default_nettype wire
