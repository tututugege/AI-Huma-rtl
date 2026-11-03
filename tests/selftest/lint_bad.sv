module wrong_name (input wire clk, input logic a, output logic b);
  localparam depth = 4;
  logic r_q, n_d;
  always @(posedge clk) begin
    r_q = a;
  end
  always_ff @(posedge clk) begin
    n_d <= a;
    count <= a;
  end
  always_comb begin
    r_q = a;
    b <= a;
  end
  initial $display("hi");
endmodule
