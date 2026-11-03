// Test wrapper: decode + compute of the fpu (no state), so a differential test can run tens of millions of vectors.
module fpu_exec_tb (
  input  logic [6:0]  func7,
  input  logic [2:0]  func3,
  input  logic        rs2_bit0,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] result,
  output logic [3:0]  latency_minus_1
);
  import fpu_pkg::*;
  logic [NKIND-1:0] kind;
  fpu_decode u_dec (.func7(func7), .func3(func3), .rs2_bit0(rs2_bit0), .kind(kind), .latency_minus_1(latency_minus_1));
  fpu_compute u_cmp (.kind(kind), .func3(func3), .a(a), .b(b), .result(result));
endmodule
