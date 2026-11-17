// Self-check of mul_core: the structural Wallace tree (STRUCT = 1) against the behavioural product (STRUCT = 0), same inputs, same latency.
`default_nettype none
module mul_check_top
  import ttg_cfg_pkg::*;
(
  input  logic        clk,
  input  logic [1:0]  func3,
  input  logic        is_word,
  input  logic [XLEN_BITS-1:0] a,
  input  logic [XLEN_BITS-1:0] b,
  output logic [XLEN_BITS-1:0] r_beh,
  output logic [XLEN_BITS-1:0] r_tree
);
  mul_core #(.STRUCT(1'b0)) u_beh  (.clk(clk), .func3(func3), .is_word(is_word), .src1_rdata(a), .src2_rdata(b), .result(r_beh));
  mul_core #(.STRUCT(1'b1)) u_tree (.clk(clk), .func3(func3), .is_word(is_word), .src1_rdata(a), .src2_rdata(b), .result(r_tree));
endmodule
`default_nettype wire
