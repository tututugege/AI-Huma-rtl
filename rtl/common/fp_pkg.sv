// Ref: back-end/include/config.h  FP / FPRF_NUM; F/D constants shared by the PRF, the execution units and the Exu
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files; a package linted alone looks unused
package fp_pkg;
  import ttg_cfg_pkg::*;

  localparam bit FP_EN = (FPRF_NUM != 0);        // the core has an FP register file and FP units
  localparam int FLEN = 64;                      // F/D register width (also on rv32)
  localparam int FW = FP_EN ? FLEN : 1;          // width of the FP data buses (a 1-bit stub, tied to 0, without F/D)
  localparam int FFLAGS_W = 5;                   // NV DZ OF UF NX

  // 64 bits wide and fld returns all of it: boxing there needs the load width (not carried: rv64 F/D is not built).
  // 64 bits wide and fld returns all of it: boxing there needs the load width (not carried yet: rv64 F/D is not built).
  function automatic logic [FW-1:0] fp_load_box(input logic [31:0] w);
    return FW'({32'hFFFF_FFFF, w});
  endfunction

  // model latency (cycles) of fdiv / fsqrt (S or D) from funct7: [1:0] = fmt (1 = D), [6:2] = funct5 (0x0b = fsqrt)
  localparam int FP_LAT_MAX = FP_FSQRT_D_LAT;
  localparam int FP_LAT_W = $clog2(FP_LAT_MAX);   // the iteration counter starts at latency - 1 <= FP_LAT_MAX - 1
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: funct7[1] (fmt high bit) is not part of the class
  function automatic int fp_div_latency(input logic [6:0] func7);
    logic d, sq;
    d  = func7[0];
    sq = (func7[6:2] == 5'h0b);
    if (sq) return d ? FP_FSQRT_D_LAT : FP_FSQRT_S_LAT;
    else    return d ? FP_FDIV_D_LAT : FP_FDIV_S_LAT;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
endpackage
`default_nettype wire
