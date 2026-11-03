// Ref: (new primitive, fpu prefix) count leading zeros
`default_nettype none

// Leading-zero count of a W-bit vector (an all-zero input reports count 0 with all_zero set).
module fpu_clz #(
  parameter int W    = 32,
  parameter int CNTW = $clog2(W)
) (
  input  logic [W-1:0]    x,
  output logic [CNTW-1:0] count,
  output logic            all_zero
);

  logic [W-1:0] x_rev;
  logic [W-1:0] lead_onehot;
  logic [CNTW-1:0] lead_idx;
  logic any_set;

  always_comb begin
    for (int i = 0; i < W; i++) x_rev[i] = x[W-1-i];
  end

  ttg_first_set #(.N(W)) u_first (.req(x_rev), .onehot(lead_onehot), .any(any_set));
  ttg_onehot_to_idx #(.N(W)) u_idx (.onehot(lead_onehot), .idx(lead_idx));

  assign count    = lead_idx;
  assign all_zero = ~any_set;

endmodule

`default_nettype wire
