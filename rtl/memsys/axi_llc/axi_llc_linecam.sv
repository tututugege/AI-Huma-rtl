`default_nettype none
// Ref: AXI_LLC.cpp  find_mshr_by_line_addr / victim_line_pending / write_line_pending (scan loops)
// Content-addressable compare of one line address against N tracked addresses: hit = any valid entry equal.
module axi_llc_linecam #(
  parameter int N = 8
) (
  input  logic [N-1:0]       vld,
  input  logic [N-1:0][31:0] addr,
  input  logic [31:0]        line,
  output logic               hit
);
  logic [N-1:0] eq;
  always_comb begin
    for (int i = 0; i < N; i++) eq[i] = vld[i] && addr[i] == line;
  end
  assign hit = |eq;
endmodule

`default_nettype wire
