// Ref: (new common primitive) find-first-set, lowest index has priority
`default_nettype none

module ttg_first_set #(
  parameter int N = 8
) (
  input  logic [N-1:0] req,
  output logic [N-1:0] onehot,
  output logic         any
);

  // isolate the lowest set bit: req & -req (two's complement), no search loop
  always_comb begin
    onehot = req & (~req + N'(1));
    any    = |req;
  end

endmodule

`default_nettype wire
