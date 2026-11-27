// Ref: docs/modules/chip_top.md  CRG slow-clock to core-clock edge synchronizer
`default_nettype none

// Converts rising edges of a slow asynchronous clock (e.g. clk_rtc) into single-cycle pulses in dst clk.
module soc_cdc_pulse (
  input  logic dst_clk,
  input  logic dst_rst_n,
  input  logic src_sig,
  output logic pulse_out
);

  logic [2:0] sync_q;

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) sync_q <= 3'b000;
    else            sync_q <= {sync_q[1:0], src_sig};
  end

  assign pulse_out = sync_q[1] & ~sync_q[2];

endmodule

`default_nettype wire
