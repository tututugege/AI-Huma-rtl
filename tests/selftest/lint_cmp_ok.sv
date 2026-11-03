// Ref: (svlint selftest) comparison with <= inside always_comb must not be read as an assignment
`default_nettype none
module lint_cmp_ok (
  input  logic [3:0] a,
  output logic       b
);
  always_comb begin
    b = 1'b0;
    if (a <= 4'd3) b = 1'b1;
    for (int i = 0; i < 2; i++) begin
      if (a[i] <= 1'b0) b = 1'b1;
    end
  end
endmodule
`default_nettype wire
