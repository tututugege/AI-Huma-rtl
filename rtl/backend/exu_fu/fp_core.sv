// Ref: back-end/Exu/include/Fu.h  FP units (the arithmetic itself: function-model Ref_cpu::RVFD)
`default_nettype none

// F/D arithmetic of one uop, combinational: result (the FP register value, or the integer result in the low XLEN bits)
// and the accrued exception flags. Simulation computes it with Berkeley softfloat through DPI-C (tb/fp_dpi/fp_dpi.cpp,
// bit-exact against the function model, tests/fp_dpi); it is replaced by a synthesizable datapath in S7.
// Instruction fields come from the uop: imm[16:12] = inst[6:2] (which opcode), imm[11:0] = inst[31:20] (funct7 | rs2).
module fp_core
  import ttg_cfg_pkg::*;
(
  input  logic [2:0]            func3,        // rounding mode / funct3
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only imm[16:0] carry instruction bits
  input  logic [31:0]           imm,          // {.., inst[6:2], inst[31:20]}
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0]  int_src,      // integer rs1 (fmv.w.x, fcvt.*.w, ...)
  input  logic [63:0]           fsrc1,
  input  logic [63:0]           fsrc2,
  input  logic [63:0]           fsrc3,
  input  logic [2:0]            frm,          // fcsr.frm for the dynamic rounding mode (func3 == 7)
  output logic [63:0]           result,
  output logic [4:0]            fflags,
  output logic                  illegal       // reserved encoding / rounding mode: an illegal-instruction exception
);

`ifndef SYNTHESIS
  import "DPI-C" pure function longint unsigned fp_dpi_res(input int unsigned op5, input int unsigned f3,
      input int unsigned f7rs2, input longint unsigned a, input longint unsigned b, input longint unsigned c,
      input longint unsigned xi, input int unsigned frm, input int unsigned xlen);
  import "DPI-C" pure function int unsigned fp_dpi_flags(input int unsigned op5, input int unsigned f3,
      input int unsigned f7rs2, input longint unsigned a, input longint unsigned b, input longint unsigned c,
      input longint unsigned xi, input int unsigned frm, input int unsigned xlen);

  import "DPI-C" pure function int unsigned fp_dpi_bad(input int unsigned op5, input int unsigned f3,
      input int unsigned f7rs2, input longint unsigned a, input longint unsigned b, input longint unsigned c,
      input longint unsigned xi, input int unsigned frm, input int unsigned xlen);

  logic [31:0] op5, f7rs2, rm, fr;
  logic [63:0] xi;
  always_comb begin
    op5   = {27'd0, imm[16:12]};
    f7rs2 = {20'd0, imm[11:0]};
    rm    = {29'd0, func3};
    fr    = {29'd0, frm};
    xi    = 64'(int_src);
    result = fp_dpi_res(op5, rm, f7rs2, fsrc1, fsrc2, fsrc3, xi, fr, 32'(XLEN_BITS));
    fflags = 5'(fp_dpi_flags(op5, rm, f7rs2, fsrc1, fsrc2, fsrc3, xi, fr, 32'(XLEN_BITS)));
    illegal = (fp_dpi_bad(op5, rm, f7rs2, fsrc1, fsrc2, fsrc3, xi, fr, 32'(XLEN_BITS)) != 32'd0);
  end
`else
  // synthesis placeholder until the datapath exists (S7)
  assign result = '0;
  assign fflags = '0;
  assign illegal = 1'b0;
`endif

endmodule

`default_nettype wire
