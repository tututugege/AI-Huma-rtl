`default_nettype none
module div_check_top import ttg_cfg_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 accept,
  input  logic                 run,
  input  logic [1:0]           func3,
  input  logic                 is_word,
  input  logic [XLEN_BITS-1:0] a,
  input  logic [XLEN_BITS-1:0] b,
  output logic [4:0]           lat_beh,
  output logic [4:0]           lat_str,
  output logic [XLEN_BITS-1:0] res_beh,
  output logic [XLEN_BITS-1:0] res_str
);
  div_core #(.STRUCT(1'b0)) u_beh (
    .clk(clk), .rst_n(rst_n), .accept(accept), .run(run),
    .func3(func3), .is_word(is_word), .src1_rdata(a), .src2_rdata(b),
    .lat_m1(lat_beh), .result(res_beh)
  );
  div_core #(.STRUCT(1'b1)) u_str (
    .clk(clk), .rst_n(rst_n), .accept(accept), .run(run),
    .func3(func3), .is_word(is_word), .src1_rdata(a), .src2_rdata(b),
    .lat_m1(lat_str), .result(res_str)
  );
endmodule
`default_nettype wire
