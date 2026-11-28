// Synthesizable RV64FD FCVT core: fcvt.s.d, fcvt.d.s, fcvt.{w,wu,l,lu}.{s,d}.
// Combinational; bit-exact against Berkeley SoftFloat (verified by scripts/fp_synth_check.sh).
`default_nettype none
module fp_fcvt_core
  import ttg_cfg_pkg::*;
  import fp_arith_pkg::*;
(
  input  logic [2:0]  func3,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] imm,          // imm[11:5]=funct7, imm[4:0]=rs2
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [63:0] fsrc1,
  input  logic [2:0]  frm,
  output logic [63:0] result,
  output logic [4:0]  fflags,
  output logic        illegal
);

  logic [6:0]  funct7;
  logic [4:0]  funct5, rs2;
  logic [1:0]  fmt;
  logic        is_d;
  logic [2:0]  rm;

  logic [31:0] a32;

  /* verilator lint_off LATCH */  // block-local temporaries, each read only on the path that assigns it: no latch
  always_comb begin
    funct7  = imm[11:5];
    rs2     = imm[4:0];
    fmt     = funct7[1:0];
    funct5  = funct7[6:2];
    is_d    = (fmt == 2'd1);
    rm      = fp_resolve_rm(func3, frm);
    a32     = fp_unbox32(fsrc1);

    result  = 64'd0;
    fflags  = 5'd0;
    illegal = 1'b0;

    if (fmt > 2'd1 || !fp_rm_valid(rm)) begin
      illegal = 1'b1;
    end else if (funct5 == 5'h08) begin
      // ---- FCVT.D.S (is_d=1, rs2=0) and FCVT.S.D (is_d=0, rs2=1) ----
      if (is_d) begin
        if (rs2 != 5'd0) begin
          illegal = 1'b1;
        end else begin
          logic        sa;
          logic [7:0]  ea;
          logic [22:0] ma;
          sa = a32[31];
          ea = a32[30:23];
          ma = a32[22:0];
          if (&ea) begin
            if (ma != 23'd0) begin
              result         = CANON_NAN64;
              fflags[FLG_NV] = !ma[22];
            end else begin
              result = {sa, 11'h7ff, 52'd0};
            end
          end else if (ea == 8'd0) begin
            if (ma == 23'd0) begin
              result = {sa, 63'd0};
            end else begin
              logic [6:0]  lz;
              /* verilator lint_off UNUSEDSIGNAL */  // the normalising shift keeps only the bits the result needs
              logic [63:0] norm;
              /* verilator lint_on UNUSEDSIGNAL */
              logic [10:0] ed;
              lz     = clz64({ma, 41'd0});       // 0..22
              norm   = {ma, 41'd0} << (lz[4:0] + 5'd1);
              ed     = 11'd896 - {4'd0, lz};
              result = {sa, ed, norm[63:12]};
            end
          end else begin
            result = {sa, {3'd0, ea} + 11'd896, ma, 29'd0};
          end
        end
      end else begin
        if (rs2 != 5'd1) begin
          illegal = 1'b1;
        end else begin
          logic        sa;
          logic [10:0] ea;
          logic [51:0] ma;
          sa = fsrc1[63];
          ea = fsrc1[62:52];
          ma = fsrc1[51:0];
          if (&ea) begin
            if (ma != 52'd0) begin
              result         = fp_nanbox32(CANON_NAN32);
              fflags[FLG_NV] = !ma[51];
            end else begin
              result = fp_nanbox32({sa, 8'hff, 23'd0});
            end
          end else if (ea == 11'd0 && ma == 52'd0) begin
            result = fp_nanbox32({sa, 31'd0});
          end else begin
            logic signed [11:0] e_s;
            e_s = $signed({1'b0, ea}) - 12'sd896;
            if (e_s >= 12'sd1) begin
              logic        g, s, rinc;
              logic [23:0] mant_inc;
              logic signed [11:0] e_out;
              g        = ma[28];
              s        = |ma[27:0];
              rinc     = fp_round_inc(rm, sa, ma[29], g, s);
              mant_inc = {1'b0, ma[51:29]} + {23'd0, rinc};
              e_out    = e_s + {11'd0, mant_inc[23]};
              if (e_out >= 12'sd255) begin
                logic max_fin;
                fflags[FLG_OF] = 1'b1;
                fflags[FLG_NX] = 1'b1;
                max_fin        = (rm == 3'd1) || (rm == 3'd2 && !sa) || (rm == 3'd3 && sa);
                result         = fp_nanbox32(max_fin ? {sa, 8'hfe, 23'h7fffff} : {sa, 8'hff, 23'd0});
              end else begin
                fflags[FLG_NX] = g | s;
                result         = fp_nanbox32({sa, e_out[7:0], mant_inc[22:0]});
              end
            end else begin
              // Subnormal or underflow (includes double subnormals where ea == 0)
              logic [11:0] rsh;
              /* verilator lint_off UNUSEDSIGNAL */  // the normalising shift keeps only the bits the result needs
              logic [53:0] sig54, shifted, mask;
              /* verilator lint_on UNUSEDSIGNAL */
              logic        g, s, rinc, lost, tiny_after;
              logic [23:0] mant_inc;
              rsh   = 12'd1 - e_s;
              sig54 = {1'b1, ma, 1'b0};
              if (ea == 11'd0 || rsh >= 12'd26) begin
                shifted = 54'd0;
                g       = 1'b0;
                s       = 1'b1;
              end else begin
                shifted = sig54 >> rsh[4:0];
                mask    = (54'd1 << rsh[4:0]) - 54'd1;
                lost    = (sig54 & mask) != 54'd0;
                g       = shifted[29];
                s       = (|shifted[28:0]) | lost;
              end
              rinc     = fp_round_inc(rm, sa, shifted[30], g, s);
              mant_inc = {1'b0, shifted[52:30]} + {23'd0, rinc};
              // IEEE-754 tininess after rounding (unbounded exponent, 24-bit significand):
              // not tiny only if e_s == 0 and rounding at 24-bit precision also carries to 2^-126
              tiny_after = !((e_s == 12'sd0) && (&ma[51:29]) &&
                             fp_round_inc(rm, sa, ma[29], ma[28], |ma[27:0]));
              fflags[FLG_NX] = g | s;
              fflags[FLG_UF] = (g | s) && tiny_after;
              result         = fp_nanbox32({sa, 7'd0, mant_inc[23], mant_inc[22:0]});
            end
          end
        end
      end
    end else if (funct5 == 5'h18) begin
      // ---- FCVT.{W,WU,L,LU}.{S,D} ----
      if (rs2 > 5'd3) begin
        illegal = 1'b1;
      end else begin
        logic        is_long, is_signed, sign;
        logic        is_nan, is_inf, is_zero, is_sub;
        logic signed [11:0] e_unb;
        logic [52:0] sig;
        logic [63:0] clamp_max, clamp_min;

        is_long   = rs2[1];
        is_signed = !rs2[0];

        if (is_long) begin
          clamp_max = is_signed ? 64'h7fff_ffff_ffff_ffff : 64'hffff_ffff_ffff_ffff;
          clamp_min = is_signed ? 64'h8000_0000_0000_0000 : 64'h0000_0000_0000_0000;
        end else begin
          clamp_max = is_signed ? 64'h0000_0000_7fff_ffff : 64'hffff_ffff_ffff_ffff;
          clamp_min = is_signed ? 64'hffff_ffff_8000_0000 : 64'h0000_0000_0000_0000;
        end

        if (is_d) begin
          sign    = fsrc1[63];
          is_nan  = (&fsrc1[62:52]) && (fsrc1[51:0] != 52'd0);
          is_inf  = (&fsrc1[62:52]) && (fsrc1[51:0] == 52'd0);
          is_zero = (fsrc1[62:0] == 63'd0);
          is_sub  = (fsrc1[62:52] == 11'd0) && (fsrc1[51:0] != 52'd0);
          e_unb   = is_sub ? -12'sd1022 : ($signed({1'b0, fsrc1[62:52]}) - 12'sd1023);
          sig     = {1'b1, fsrc1[51:0]};
        end else begin
          sign    = a32[31];
          is_nan  = (&a32[30:23]) && (a32[22:0] != 23'd0);
          is_inf  = (&a32[30:23]) && (a32[22:0] == 23'd0);
          is_zero = (a32[30:0] == 31'd0);
          is_sub  = (a32[30:23] == 8'd0) && (a32[22:0] != 23'd0);
          e_unb   = is_sub ? -12'sd126 : ($signed({4'd0, a32[30:23]}) - 12'sd127);
          sig     = {1'b1, a32[22:0], 29'd0};
        end

        if (is_nan) begin
          result         = clamp_max;
          fflags[FLG_NV] = 1'b1;
        end else if (is_zero) begin
          result = 64'd0;
        end else if (is_inf || e_unb >= 12'sd64) begin
          result         = sign ? clamp_min : clamp_max;
          fflags[FLG_NV] = 1'b1;
        end else begin
          logic [63:0] int_part;
          logic [64:0] mag_r;
          logic        g, s, rinc, ovf;

          if (e_unb < 12'sd0) begin
            int_part = 64'd0;
            g        = (!is_sub) && (e_unb == -12'sd1);
            s        = is_sub || (e_unb < -12'sd1) || (|sig[51:0]);
          end else if (e_unb >= 12'sd52) begin
            int_part = {11'd0, sig} << (e_unb[5:0] - 6'd52);
            g        = 1'b0;
            s        = 1'b0;
          end else begin
            logic [5:0]  rsh;
            logic [52:0] smask;
            rsh      = 6'd52 - e_unb[5:0];   // 1..52
            int_part = {11'd0, sig} >> rsh;
            g        = sig[rsh - 6'd1];
            smask    = (rsh > 6'd1) ? ((53'd1 << (rsh - 6'd1)) - 53'd1) : 53'd0;
            s        = (sig & smask) != 53'd0;
          end

          rinc  = fp_round_inc(rm, sign, int_part[0], g, s);
          mag_r = {1'b0, int_part} + {64'd0, rinc};

          if (is_long) begin
            if (is_signed) ovf = sign ? (mag_r > 65'h0_8000_0000_0000_0000) : (mag_r > 65'h0_7fff_ffff_ffff_ffff);
            else           ovf = (sign && (mag_r != 65'd0)) || (!sign && mag_r[64]);
          end else begin
            if (is_signed) ovf = sign ? (mag_r > 65'h0_0000_0000_8000_0000) : (mag_r > 65'h0_0000_0000_7fff_ffff);
            else           ovf = (sign && (mag_r != 65'd0)) || (!sign && (mag_r > 65'h0_0000_0000_ffff_ffff));
          end

          if (ovf) begin
            result         = sign ? clamp_min : clamp_max;
            fflags[FLG_NV] = 1'b1;
          end else begin
            logic [63:0] fin;
            fin            = sign ? (64'd0 - mag_r[63:0]) : mag_r[63:0];
            result         = is_long ? fin : {{32{fin[31]}}, fin[31:0]};
            fflags[FLG_NX] = g | s;
          end
        end
      end
    end else begin
      illegal = 1'b1;
    end
  end
  /* verilator lint_on LATCH */

endmodule
`default_nettype wire
