`default_nettype none
module fp_synth_check_top import ttg_cfg_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        div_accept,
  input  logic        div_run,
  input  logic [2:0]  func3,
  input  logic [31:0] imm,
  input  logic [63:0] int_src,
  input  logic [63:0] fsrc1,
  input  logic [63:0] fsrc2,
  input  logic [63:0] fsrc3,
  input  logic [2:0]  frm,
  output logic [63:0] misc_res,
  output logic [4:0]  misc_flg,
  output logic        misc_bad,
  output logic [63:0] i2f_res,
  output logic [4:0]  i2f_flg,
  output logic        i2f_bad,
  output logic [63:0] fcvt_res,
  output logic [4:0]  fcvt_flg,
  output logic        fcvt_bad,
  output logic [63:0] fma_res,
  output logic [4:0]  fma_flg,
  output logic        fma_bad,
  output logic [63:0] fdiv_res,
  output logic [4:0]  fdiv_flg,
  output logic        fdiv_bad
);
  fp_misc_core u_misc (
    .func3(func3), .imm(imm), .fsrc1(fsrc1), .fsrc2(fsrc2),
    .result(misc_res), .fflags(misc_flg), .illegal(misc_bad)
  );
  fp_i2f_core u_i2f (
    .func3(func3), .imm(imm), .int_src(int_src), .frm(frm),
    .result(i2f_res), .fflags(i2f_flg), .illegal(i2f_bad)
  );
  fp_fcvt_core u_fcvt (
    .func3(func3), .imm(imm), .fsrc1(fsrc1), .frm(frm),
    .result(fcvt_res), .fflags(fcvt_flg), .illegal(fcvt_bad)
  );
  fp_fma_core u_fma (
    .clk(clk), .func3(func3), .imm(imm), .fsrc1(fsrc1), .fsrc2(fsrc2), .fsrc3(fsrc3), .frm(frm),
    .result(fma_res), .fflags(fma_flg), .illegal(fma_bad)
  );
  fp_div_core u_fdiv (
    .clk(clk), .rst_n(rst_n), .accept(div_accept), .run(div_run),
    .func3(func3), .imm(imm), .fsrc1(fsrc1), .fsrc2(fsrc2), .frm(frm),
    .result(fdiv_res), .fflags(fdiv_flg), .illegal(fdiv_bad)
  );
endmodule
`default_nettype wire
