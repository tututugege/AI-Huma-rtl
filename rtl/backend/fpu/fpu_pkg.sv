// Ref: back-end/Exu/include/FPU.h  class FPUSoftfloat (instruction classes, latencies, rounding-mode decode)
`default_nettype none

/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files; linted alone none is used
package fpu_pkg;

  // ---- instruction kinds (one-hot index) decoded from func7/func3/imm[0] of a UOP_FP uop, FPU.h impl_compute ----
  localparam int NKIND      = 18;
  localparam int K_ADD      = 0;   // func7>>2 == 0
  localparam int K_SUB      = 1;   // func7>>2 == 1
  localparam int K_MUL      = 2;   // func7>>2 == 2
  localparam int K_DIV      = 3;   // func7>>2 == 3
  localparam int K_SQRT     = 4;   // func7 == 0x2C
  localparam int K_CVT_W    = 5;   // func7 == 0x60, rs2 == 0   fcvt.w.s
  localparam int K_CVT_WU   = 6;   // func7 == 0x60, rs2 == 1   fcvt.wu.s
  localparam int K_CVT_SW   = 7;   // func7 == 0x68, rs2 == 0   fcvt.s.w
  localparam int K_CVT_SWU  = 8;   // func7 == 0x68, rs2 == 1   fcvt.s.wu
  localparam int K_SGNJ     = 9;   // func7 == 0x10, func3 == 0
  localparam int K_SGNJN    = 10;  // func3 == 1
  localparam int K_SGNJX    = 11;  // func3 == 2
  localparam int K_MIN      = 12;  // func7 == 0x14, func3 == 0
  localparam int K_MAX      = 13;  // func3 == 1
  localparam int K_EQ       = 14;  // func7 == 0x50, func3 == 2
  localparam int K_LT       = 15;  // func3 == 1
  localparam int K_LE       = 16;  // func3 == 0
  localparam int K_CLASS    = 17;  // func7 == 0x70

  // ---- latency (cycles from accept to complete), FPUSoftfloat::calculate_latency ----
  localparam int LAT_FADD = 5;
  localparam int LAT_FMUL = 3;
  localparam int LAT_FDIV = 10;
  localparam int LAT_FCVT = 3;
  localparam int LAT_W    = 4;   // counter width: counts LAT-1 down to 0 (max 9)

  // ---- rounding mode: softfloat's view of func3 (rm=7 DYN is treated as RNE, 5 behaves as round-toward-zero) ----
  typedef struct packed {
    logic rne;   // round to nearest, ties to even   (rm 0, 7)
    logic rdn;   // toward -inf                       (rm 2)
    logic rup;   // toward +inf                       (rm 3)
    logic rmm;   // to nearest, ties to max magnitude (rm 4)
  } fpu_rm_t;     // none set: toward zero              (rm 1, 5; rm 6 = round-to-odd in softfloat is not implemented)

  function automatic fpu_rm_t fpu_rm_decode(input logic [2:0] rm);
    fpu_rm_decode.rne = (rm == 3'd0) || (rm == 3'd7);
    fpu_rm_decode.rdn = (rm == 3'd2);
    fpu_rm_decode.rup = (rm == 3'd3);
    fpu_rm_decode.rmm = (rm == 3'd4);
  endfunction

  // Encoding the gate netlists understand (0..4 are the IEEE modes they implement; fpcmp: 5/6/7 differ from softfloat).
  function automatic logic [2:0] fpu_rm_net(input fpu_rm_t m);
    fpu_rm_net = {m.rmm, m.rup | m.rdn, m.rup | ~(m.rne | m.rdn | m.rmm)};
  endfunction

  // Round-to-integer / pack increment decision for "guard" and "sticky-or-lsb" information.
  //   round_bit: first discarded bit; sticky: OR of all lower discarded bits; lsb: kept lsb; sign: result sign.
  function automatic logic fpu_round_inc(input fpu_rm_t m, input logic round_bit, input logic sticky,
                                         input logic lsb, input logic sign);
    fpu_round_inc = (m.rne & round_bit & (sticky | lsb)) | (m.rmm & round_bit) |
                    (m.rdn & sign & (round_bit | sticky)) | (m.rup & ~sign & (round_bit | sticky));
  endfunction

  function automatic logic fpu_is_nan(input logic [30:0] mag);   // magnitude bits: sign does not matter
    fpu_is_nan = (mag[30:23] == 8'hFF) && (mag[22:0] != 23'd0);
  endfunction

  localparam logic [31:0] F32_QNAN = 32'h7FC00000;  // softfloat (RISC-V specialisation) default NaN

endpackage

`default_nettype wire
