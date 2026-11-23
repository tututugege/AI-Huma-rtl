// Synthesizable RV64FD I2F core: fcvt.{s,d}.{w,wu,l,lu} and fmv.{w,d}.x.
// Combinational; bit-exact against Berkeley SoftFloat (verified by scripts/fp_synth_check.sh).
`default_nettype none
module fp_i2f_core
  import ttg_cfg_pkg::*;
  import fp_arith_pkg::*;
(
  input  logic [2:0]           func3,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]          imm,        // imm[11:5]=funct7, imm[4:0]=rs2
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] int_src,
  input  logic [2:0]           frm,
  output logic [63:0]          result,
  output logic [4:0]           fflags,
  output logic                 illegal
);

  logic [6:0]  funct7;
  logic [4:0]  funct5, rs2;
  logic [1:0]  fmt;
  logic        is_d;
  logic [2:0]  rm;

  // Integer magnitude & normalization
  logic        is_long, is_signed, sign;
  logic [63:0] val_ext, mag, norm;
  logic [6:0]  lz;
  logic        is_zero;

  always_comb begin
    funct7    = imm[11:5];
    rs2       = imm[4:0];
    fmt       = funct7[1:0];
    funct5    = funct7[6:2];
    is_d      = (fmt == 2'd1);
    rm        = fp_resolve_rm(func3, frm);

    is_long   = rs2[1];
    is_signed = !rs2[0];

    if (is_long) begin
      val_ext = int_src;
      sign    = is_signed && int_src[63];
    end else begin
      val_ext = is_signed ? {{32{int_src[31]}}, int_src[31:0]} : {32'd0, int_src[31:0]};
      sign    = is_signed && int_src[31];
    end

    mag     = sign ? (64'd0 - val_ext) : val_ext;
    is_zero = (mag == 64'd0);
    lz      = clz64(mag);
    norm    = mag << lz[5:0];   // norm[63] = 1 when !is_zero

    result  = 64'd0;
    fflags  = 5'd0;
    illegal = 1'b0;

    if (fmt > 2'd1) begin
      illegal = 1'b1;
    end else if (funct5 == 5'h1e) begin
      // FMV.W.X / FMV.D.X
      if (rs2 != 5'd0 || func3 != 3'd0) begin
        illegal = 1'b1;
      end else begin
        result = is_d ? int_src : fp_nanbox32(int_src[31:0]);
      end
    end else if (funct5 == 5'h1a) begin
      // FCVT.{S,D}.{W,WU,L,LU}
      if (rs2 > 5'd3 || !fp_rm_valid(rm)) begin
        illegal = 1'b1;
      end else if (is_zero) begin
        result = is_d ? 64'd0 : fp_nanbox32(32'd0);
      end else if (is_d) begin
        // Double: 52-bit mantissa = norm[62:11], g = norm[10], s = |norm[9:0]
        logic [10:0] exp_raw, exp_out;
        logic [52:0] mant_inc;
        logic        g, s, rinc;
        exp_raw  = 11'd1086 - {4'd0, lz};   // 1023 + (63 - lz)
        g        = norm[10];
        s        = |norm[9:0];
        rinc     = fp_round_inc(rm, sign, norm[11], g, s);
        mant_inc = {1'b0, norm[62:11]} + {52'd0, rinc};
        exp_out  = exp_raw + {10'd0, mant_inc[52]};
        result   = {sign, exp_out, mant_inc[51:0]};
        fflags[FLG_NX] = g | s;
      end else begin
        // Single: 23-bit mantissa = norm[62:40], g = norm[39], s = |norm[38:0]
        logic [7:0]  exp_raw, exp_out;
        logic [23:0] mant_inc;
        logic        g, s, rinc;
        exp_raw  = 8'd190 - {1'b0, lz};     // 127 + (63 - lz)
        g        = norm[39];
        s        = |norm[38:0];
        rinc     = fp_round_inc(rm, sign, norm[40], g, s);
        mant_inc = {1'b0, norm[62:40]} + {23'd0, rinc};
        exp_out  = exp_raw + {7'd0, mant_inc[23]};
        result   = fp_nanbox32({sign, exp_out, mant_inc[22:0]});
        fflags[FLG_NX] = g | s;
      end
    end else begin
      illegal = 1'b1;
    end
  end

endmodule
`default_nettype wire
