// Synthesizable RV64FD FMISC core: fsgnj*, fmin/fmax, feq/flt/fle, fclass, fmv.x.w/d.
// Combinational; bit-exact against Berkeley SoftFloat (verified by scripts/fp_synth_check.sh).
`default_nettype none
module fp_misc_core
  import ttg_cfg_pkg::*;
  import fp_arith_pkg::*;
(
  input  logic [2:0]  func3,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] imm,          // imm[16:12]=op5, imm[11:5]=funct7, imm[4:0]=rs2
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [63:0] fsrc1,
  input  logic [63:0] fsrc2,
  output logic [63:0] result,
  output logic [4:0]  fflags,
  output logic        illegal
);

  logic [6:0] funct7;
  logic [4:0] funct5, rs2;
  logic [1:0] fmt;
  logic       is_d;

  logic [31:0] a32, b32;
  logic        sa, sb;
  logic [10:0] ea, eb;
  logic [51:0] ma, mb;
  logic        ea_zero, eb_zero, ea_max, eb_max;
  logic        ma_zero, mb_zero;
  logic        a_zero, b_zero, a_sub, b_sub, a_inf, b_inf, a_nan, b_nan, a_snan, b_snan;
  logic        mag_eq, mag_lt, a_lt_b, a_eq_b;

  always_comb begin
    funct7 = imm[11:5];
    rs2    = imm[4:0];
    fmt    = funct7[1:0];
    funct5 = funct7[6:2];
    is_d   = (fmt == 2'd1);

    a32 = fp_unbox32(fsrc1);
    b32 = fp_unbox32(fsrc2);

    // Unified unpack into D-width fields (S placed at top of mantissa, exp zero-extended)
    if (is_d) begin
      sa      = fsrc1[63];
      sb      = fsrc2[63];
      ea      = fsrc1[62:52];
      eb      = fsrc2[62:52];
      ma      = fsrc1[51:0];
      mb      = fsrc2[51:0];
      ea_max  = &fsrc1[62:52];
      eb_max  = &fsrc2[62:52];
    end else begin
      sa      = a32[31];
      sb      = b32[31];
      ea      = {3'b0, a32[30:23]};
      eb      = {3'b0, b32[30:23]};
      ma      = {a32[22:0], 29'd0};
      mb      = {b32[22:0], 29'd0};
      ea_max  = &a32[30:23];
      eb_max  = &b32[30:23];
    end

    ea_zero = (ea == 11'd0);
    eb_zero = (eb == 11'd0);
    ma_zero = (ma == 52'd0);
    mb_zero = (mb == 52'd0);

    a_zero  = ea_zero && ma_zero;
    b_zero  = eb_zero && mb_zero;
    a_sub   = ea_zero && !ma_zero;
    b_sub   = eb_zero && !mb_zero;
    a_inf   = ea_max  && ma_zero;
    b_inf   = eb_max  && mb_zero;
    a_nan   = ea_max  && !ma_zero;
    b_nan   = eb_max  && !mb_zero;
    a_snan  = a_nan   && !ma[51];
    b_snan  = b_nan   && !mb[51];

    // Magnitude & signed comparison for non-NaN operands
    mag_eq  = ({ea, ma} == {eb, mb});
    mag_lt  = ({ea, ma} <  {eb, mb});
    a_eq_b  = (a_zero && b_zero) || ((sa == sb) && mag_eq);
    a_lt_b  = !(a_zero && b_zero) && (
                (sa && !sb) ? 1'b1 :
                (!sa && sb) ? 1'b0 :
                (sa ? (!mag_lt && !mag_eq) : mag_lt)
              );

    result  = 64'd0;
    fflags  = 5'd0;
    illegal = 1'b0;

    if (fmt > 2'd1) begin
      illegal = 1'b1;
    end else begin
      case (funct5)
        // FSGNJ / FSGNJN / FSGNJX
        5'h04: begin
          if (func3 > 3'd2) begin
            illegal = 1'b1;
          end else begin
            logic s_out;
            s_out = (func3 == 3'd0) ? sb : (func3 == 3'd1) ? ~sb : (sa ^ sb);
            result = is_d ? {s_out, fsrc1[62:0]} : fp_nanbox32({s_out, a32[30:0]});
          end
        end

        // FMIN / FMAX (IEEE 754-2008 / RISC-V: -0.0 < +0.0, sNaN sets NV, NaN returns other)
        5'h05: begin
          if (func3 > 3'd1) begin
            illegal = 1'b1;
          end else begin
            logic pick_b;
            fflags[FLG_NV] = a_snan || b_snan;
            if (a_nan && b_nan) begin
              result = is_d ? CANON_NAN64 : fp_nanbox32(CANON_NAN32);
            end else if (a_nan) begin
              result = is_d ? fsrc2 : fp_nanbox32(b32);
            end else if (b_nan) begin
              result = is_d ? fsrc1 : fp_nanbox32(a32);
            end else begin
              if (a_zero && b_zero) begin
                // min: -0.0 wins (sa|sb); max: +0.0 wins (sa&sb)
                pick_b = (func3 == 3'd0) ? (sb && !sa) : (!sb && sa);
              end else begin
                pick_b = (func3 == 3'd0) ? (!a_lt_b && !a_eq_b) : a_lt_b;
              end
              result = pick_b ? (is_d ? fsrc2 : fp_nanbox32(b32))
                              : (is_d ? fsrc1 : fp_nanbox32(a32));
            end
          end
        end

        // FEQ (func3=2) / FLT (func3=1) / FLE (func3=0)
        5'h14: begin
          if (func3 > 3'd2) begin
            illegal = 1'b1;
          end else begin
            logic cmp_res;
            if (func3 == 3'd2) begin
              fflags[FLG_NV] = a_snan || b_snan;
              cmp_res        = !(a_nan || b_nan) && a_eq_b;
            end else if (func3 == 3'd1) begin
              fflags[FLG_NV] = a_nan || b_nan;
              cmp_res        = !(a_nan || b_nan) && a_lt_b;
            end else begin
              fflags[FLG_NV] = a_nan || b_nan;
              cmp_res        = !(a_nan || b_nan) && (a_lt_b || a_eq_b);
            end
            result = {63'd0, cmp_res};
          end
        end

        // FMV.X.W / FMV.X.D (func3=0) and FCLASS.S / FCLASS.D (func3=1)
        5'h1c: begin
          if (rs2 != 5'd0 || func3 > 3'd1) begin
            illegal = 1'b1;
          end else if (func3 == 3'd0) begin
            // Note: FMV.X.W reads raw low 32 bits of fsrc1 without NaN-unboxing, sign-extended to 64b
            result = is_d ? fsrc1 : {{32{fsrc1[31]}}, fsrc1[31:0]};
          end else begin
            logic [9:0] cls;
            cls = 10'd0;
            if (a_nan)       cls = ma[51] ? 10'h200 : 10'h100;
            else if (a_inf)  cls = sa ? 10'h001 : 10'h080;
            else if (a_zero) cls = sa ? 10'h008 : 10'h010;
            else if (a_sub)  cls = sa ? 10'h004 : 10'h020;
            else             cls = sa ? 10'h002 : 10'h040;
            result = {54'd0, cls};
          end
        end

        default: illegal = 1'b1;
      endcase
    end
  end

endmodule
`default_nettype wire
