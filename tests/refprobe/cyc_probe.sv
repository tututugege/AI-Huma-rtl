// Ref: (harness probe only) SimContext perf.cycle
// Probe module: counts cycles from reset; matches the reference simulator's cycle counter (first cycle = 1).
`default_nettype none

module cyc_probe (
  input  wire        clk,
  input  wire        rst_n,
  input  logic       tick,
  output logic [31:0] cycle,
  output logic [63:0] cycle_w
);

  logic [63:0] cnt_q;
  logic [63:0] cnt_d;

  always_comb begin
    cnt_d   = tick ? cnt_q + 64'd1 : cnt_q;
    cycle_w = cnt_q + 64'd1;
    cycle   = cycle_w[31:0];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) cnt_q <= 64'd0;
    else        cnt_q <= cnt_d;
  end

endmodule

`default_nettype wire
