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
  // Width-tight recursive binary adder tree: internal nodes use exact min($clog2(sub_N+1), CW) bits.
  if (N <= 1) begin : g_n1
    assign count = CW'(bits[0]);
  end else if (N == 2) begin : g_n2
    localparam int WO = (CW < 2) ? CW : 2;
    logic [WO-1:0] sum2;
    assign sum2  = WO'(bits[0]) + WO'(bits[1]);
    assign count = CW'(sum2);
  end else begin : g_rec
    localparam int NL  = N / 2;
    localparam int NR  = N - NL;
    localparam int CWL = ($clog2(NL + 1) < CW) ? $clog2(NL + 1) : CW;
    localparam int CWR = ($clog2(NR + 1) < CW) ? $clog2(NR + 1) : CW;
    logic [CWL-1:0] cnt_l;
    logic [CWR-1:0] cnt_r;
    ttg_popcount #(.N(NL), .CW(CWL)) u_l (.bits(bits[NL-1:0]), .count(cnt_l));
    ttg_popcount #(.N(NR), .CW(CWR)) u_r (.bits(bits[N-1:NL]), .count(cnt_r));
    assign count = CW'(cnt_l) + CW'(cnt_r);
  end
`else
  // Fast simulation path (bit-identical to balanced adder tree above, verified by tests/common_prims)
  always_comb begin
    count = '0;
    for (int i = 0; i < N; i++) count = count + CW'(bits[i]);
  end
`endif

endmodule

`default_nettype wire
