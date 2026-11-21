// Ref: (new common primitive) AND-OR multiplexer selected by a one-hot vector (no select gives 0)
`default_nettype none

module ttg_onehot_mux #(
  parameter int N = 4,
  parameter int W = 8
) (
  input  logic [N-1:0] sel,
  input  logic [W-1:0] data [N],
  output logic [W-1:0] out
);

`ifdef SYNTHESIS
  // Balanced binary OR tree of depth ceil(log2(N)) in heap order:
  // leaves at [P-1 .. 2*P-2], internal nodes at [0 .. P-2], root at [0].
  localparam int P = (N <= 1) ? 1 : (1 << $clog2(N));

  logic [W-1:0] tree [2*P-1];

  for (genvar i = 0; i < P; i++) begin : g_leaf
    if (i < N) begin : g_in
      assign tree[P - 1 + i] = data[i] & {W{sel[i]}};
    end else begin : g_pad
      assign tree[P - 1 + i] = '0;
    end
  end

  for (genvar k = 0; k < P - 1; k++) begin : g_node
    assign tree[k] = tree[2*k + 1] | tree[2*k + 2];
  end

  assign out = tree[0];
`else
  // Fast simulation path (bit-identical for both one-hot and multi-hot sel, verified by tests/common_prims)
  always_comb begin
    out = '0;
    for (int i = 0; i < N; i++) if (sel[i]) out = out | data[i];
  end
`endif

endmodule

`default_nettype wire
