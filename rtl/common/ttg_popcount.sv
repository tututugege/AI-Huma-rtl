// Ref: (new common primitive) number of set bits
`default_nettype none

module ttg_popcount #(
  parameter int N  = 8,
  parameter int CW = $clog2(N + 1)
) (
  input  logic [N-1:0]  bits,
  output logic [CW-1:0] count
);

`ifdef SYNTHESIS
  // Balanced binary adder tree of depth ceil(log2(N)) in heap order:
  // leaves at [P-1 .. 2*P-2], internal nodes at [0 .. P-2], root at [0].
  localparam int P = (N <= 1) ? 1 : (1 << $clog2(N));

  logic [CW-1:0] tree [2*P-1];

  for (genvar i = 0; i < P; i++) begin : g_leaf
    if (i < N) begin : g_in
      assign tree[P - 1 + i] = CW'(bits[i]);
    end else begin : g_pad
      assign tree[P - 1 + i] = '0;
    end
  end

  for (genvar k = 0; k < P - 1; k++) begin : g_node
    assign tree[k] = tree[2*k + 1] + tree[2*k + 2];
  end

  assign count = tree[0];
`else
  // Fast simulation path (bit-identical to balanced adder tree above, verified by tests/common_prims)
  always_comb begin
    count = '0;
    for (int i = 0; i < N; i++) count = count + CW'(bits[i]);
  end
`endif

endmodule

`default_nettype wire
