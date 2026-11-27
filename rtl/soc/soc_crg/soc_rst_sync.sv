// Ref: docs/modules/chip_top.md  CRG async-assert / sync-deassert 2-FF reset synchronizer
`default_nettype none

module soc_rst_sync (
  input  logic clk,
  input  logic raw_rst_n,
  input  logic dft_test_mode,
  output logic rst_n
);

  logic [1:0] sync_q;

  always_ff @(posedge clk or negedge raw_rst_n) begin
    if (!raw_rst_n) sync_q <= 2'b00;
    else            sync_q <= {sync_q[0], 1'b1};
  end

  assign rst_n = dft_test_mode ? raw_rst_n : sync_q[1];

endmodule

`default_nettype wire
