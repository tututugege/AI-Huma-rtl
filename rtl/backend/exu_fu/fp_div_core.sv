// Synthesizable iterative RV64FD FDIV & FSQRT core:
//   fdiv.s (11 cyc), fsqrt.s (13 cyc), fdiv.d (19 cyc), fsqrt.d (23 cyc).
// Advances 3 quotient/root bits per run cycle (8 run cycles for S = 24 bits, 18 run cycles for D = 54 bits),
// then holds until complete. Bit-exact against Berkeley SoftFloat (verified by scripts/fp_synth_check.sh).
`default_nettype none
module fp_div_core
  import ttg_cfg_pkg::*;
  import fp_arith_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        accept,
  input  logic        run,
  input  logic [2:0]  func3,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] imm,        // imm[11:5]=funct7, imm[4:0]=rs2
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [63:0] fsrc1,
  input  logic [63:0] fsrc2,
  input  logic [2:0]  frm,
  output logic [63:0] result,
  output logic [4:0]  fflags,
  output logic        illegal
);

  // ---- state ----
  logic               is_d_q, is_sqrt_q, ill_q, spec_q, sgn_q;
  logic [2:0]         rm_q;
  logic [63:0]        spec_res_q;
  logic [4:0]         spec_flg_q;
  logic signed [12:0] exp_q;
  logic [4:0]         iters_left_q;
  logic [57:0]        rem_q;
  logic [56:0]        dvs_q;       // div: divisor (bit 54=MSB); sqrt: current root Q (bit 54=MSB)
  logic [55:0]        quo_q;       // div: quotient bits shifted in; sqrt: one-hot bit mask b_k

  // Helper: unpack S or D operand into normalized 53-bit significand + signed unbiased exp
  task automatic unpack_fp(
    input  logic        is_d,
    input  logic [63:0] raw,
    output logic        sgn,
    output logic signed [12:0] e_unb,
    output logic [52:0] sig,
    output logic        is_zero,
    output logic        is_inf,
    output logic        is_nan,
    output logic        is_snan
  );
    logic [31:0] u32;
    logic [10:0] e_raw;
    logic [51:0] m_raw;
    logic        e_max, e_zero, m_zero;
    u32 = fp_unbox32(raw);
    if (is_d) begin
      sgn    = raw[63];
      e_raw  = raw[62:52];
      m_raw  = raw[51:0];
      e_max  = &raw[62:52];
    end else begin
      sgn    = u32[31];
      e_raw  = {3'd0, u32[30:23]};
      m_raw  = {u32[22:0], 29'd0};
      e_max  = &u32[30:23];
    end
    e_zero  = (e_raw == 11'd0);
    m_zero  = (m_raw == 52'd0);
    is_zero = e_zero && m_zero;
    is_inf  = e_max  && m_zero;
    is_nan  = e_max  && !m_zero;
    is_snan = is_nan && !m_raw[51];

    if (is_zero || is_inf || is_nan) begin
      e_unb = 13'sd0;
      sig   = 53'd0;
    end else if (e_zero) begin
      logic [6:0]  lz;
      logic [63:0] norm64;
      lz     = clz64({m_raw, 12'd0});
      norm64 = {m_raw, 12'd0} << lz[5:0];
      sig    = norm64[63:11];
      e_unb  = (is_d ? -13'sd1023 : -13'sd127) - $signed({6'd0, lz});
    end else begin
      sig   = {1'b1, m_raw};
      e_unb = $signed({2'd0, e_raw}) - (is_d ? 13'sd1023 : 13'sd127);
    end
  endtask

  // ---- accept-cycle decode, special cases, and pre-alignment ----
  logic               acc_is_d, acc_is_sqrt, acc_ill, acc_spec, acc_sgn;
  logic [2:0]         acc_rm;
  logic [63:0]        acc_spec_res;
  logic [4:0]         acc_spec_flg;
  logic signed [12:0] acc_exp;
  logic [4:0]         acc_iters;
  logic [57:0]        acc_rem;
  logic [56:0]        acc_dvs;
  logic [55:0]        acc_quo;

  always_comb begin
    logic [6:0]  funct7;
    logic [4:0]  funct5, rs2;
    logic [1:0]  fmt;
    logic        sa, sb, az, ai, an, asn, bz, bi, bn, bsn;
    logic signed [12:0] ea, eb;
    logic [52:0] ma, mb;

    funct7      = imm[11:5];
    rs2         = imm[4:0];
    fmt         = funct7[1:0];
    funct5      = funct7[6:2];
    acc_is_d    = (fmt == 2'd1);
    acc_is_sqrt = (funct5 == 5'h0b);
    acc_rm      = fp_resolve_rm(func3, frm);

    acc_ill = (fmt > 2'd1) || !fp_rm_valid(acc_rm) ||
              !((funct5 == 5'h03) || (funct5 == 5'h0b && rs2 == 5'd0));

    unpack_fp(acc_is_d, fsrc1, sa, ea, ma, az, ai, an, asn);
    unpack_fp(acc_is_d, fsrc2, sb, eb, mb, bz, bi, bn, bsn);

    acc_spec     = 1'b0;
    acc_spec_res = 64'd0;
    acc_spec_flg = 5'd0;
    acc_sgn      = acc_is_sqrt ? sa : (sa ^ sb);
    acc_exp      = 13'sd0;
    acc_iters    = acc_is_d ? 5'd18 : 5'd9;   // S: 9*3=27 bits (25 used), D: 18*3=54 bits
    acc_rem      = 58'd0;
    acc_dvs      = 57'd0;
    acc_quo      = 56'd0;

    if (acc_is_sqrt) begin
      if (an || (sa && !az)) begin
        acc_spec               = 1'b1;
        acc_spec_res           = acc_is_d ? CANON_NAN64 : fp_nanbox32(CANON_NAN32);
        acc_spec_flg[FLG_NV]   = asn || (!an && sa && !az);
      end else if (ai) begin
        acc_spec     = 1'b1;
        acc_spec_res = acc_is_d ? {1'b0, 11'h7ff, 52'd0} : fp_nanbox32({1'b0, 8'hff, 23'd0});
      end else if (az) begin
        acc_spec     = 1'b1;
        acc_spec_res = acc_is_d ? {sa, 63'd0} : fp_nanbox32({sa, 31'd0});
      end else begin
        // Scale by 2^54 so bit 54 = 1.0:
        //   if ea even: rad = ma << 2 (in [1,2)), exp = ea/2
        //   if ea odd : rad = ma << 3 (in [2,4)), exp = (ea-1)/2
        // Initial root Q0 = 1.0 (1<<54), rem0 = rad - (1<<54), bit mask b1 = 1<<53
        logic [57:0] rad;
        if (ea[0]) begin
          rad     = {2'd0, ma, 3'd0};
          acc_exp = (ea - 13'sd1) >>> 1;
        end else begin
          rad     = {3'd0, ma, 2'd0};
          acc_exp = ea >>> 1;
        end
        acc_rem = rad - (58'd1 << 54);
        acc_dvs = 57'd1 << 54;   // Q
        acc_quo = 56'd1 << 53;   // b_k one-hot
      end
    end else begin
      // FDIV
      if (an || bn || (az && bz) || (ai && bi)) begin
        acc_spec               = 1'b1;
        acc_spec_res           = acc_is_d ? CANON_NAN64 : fp_nanbox32(CANON_NAN32);
        acc_spec_flg[FLG_NV]   = asn || bsn || (!an && !bn && ((az && bz) || (ai && bi)));
      end else if (bz) begin
        acc_spec               = 1'b1;
        acc_spec_res           = acc_is_d ? {acc_sgn, 11'h7ff, 52'd0} : fp_nanbox32({acc_sgn, 8'hff, 23'd0});
        acc_spec_flg[FLG_DZ]   = !ai;
      end else if (ai) begin
        acc_spec     = 1'b1;
        acc_spec_res = acc_is_d ? {acc_sgn, 11'h7ff, 52'd0} : fp_nanbox32({acc_sgn, 8'hff, 23'd0});
      end else if (az || bi) begin
        acc_spec     = 1'b1;
        acc_spec_res = acc_is_d ? {acc_sgn, 63'd0} : fp_nanbox32({acc_sgn, 31'd0});
      end else begin
        // Pre-align so quotient is strictly in [1.0, 2.0): leading bit q0 = 1
        if (ma >= mb) begin
          acc_rem = {5'd0, ma} - {5'd0, mb};
          acc_exp = ea - eb;
        end else begin
          acc_rem = {4'd0, ma, 1'b0} - {5'd0, mb};
          acc_exp = ea - eb - 13'sd1;
        end
        acc_dvs = {4'd0, mb};
        acc_quo = 56'd1;   // q0 = 1
      end
    end
  end

  // ---- run-cycle: 3 restoring steps per cycle ----
  logic [57:0] run_rem;
  logic [56:0] run_dvs;
  logic [55:0] run_quo;

  always_comb begin
    logic [57:0] r, r_sh, trial;
    logic [56:0] q_sq;
    logic [55:0] q_dv, bk;
    logic        fits;

    r    = rem_q;
    q_sq = dvs_q;
    q_dv = quo_q;
    bk   = quo_q;

    if (run && !spec_q && !ill_q && (iters_left_q != 5'd0)) begin
      for (int s = 0; s < 3; s++) begin
        if (is_sqrt_q) begin
          r_sh  = r << 1;
          trial = {q_sq, 1'b0} | {2'd0, bk};
          fits  = (r_sh >= trial);
          r     = fits ? (r_sh - trial) : r_sh;
          if (fits) q_sq = q_sq | {1'b0, bk};
          bk    = bk >> 1;
        end else begin
          r_sh  = r << 1;
          trial = {1'b0, dvs_q};
          fits  = (r_sh >= trial);
          r     = fits ? (r_sh - trial) : r_sh;
          q_dv  = {q_dv[54:0], fits};
        end
      end
    end

    run_rem = r;
    run_dvs = is_sqrt_q ? q_sq : dvs_q;
    run_quo = is_sqrt_q ? bk   : q_dv;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      is_d_q       <= 1'b0;
      is_sqrt_q    <= 1'b0;
      ill_q        <= 1'b0;
      spec_q       <= 1'b0;
      sgn_q        <= 1'b0;
      rm_q         <= 3'd0;
      spec_res_q   <= 64'd0;
      spec_flg_q   <= 5'd0;
      exp_q        <= 13'sd0;
      iters_left_q <= 5'd0;
      rem_q        <= 58'd0;
      dvs_q        <= 57'd0;
      quo_q        <= 56'd0;
    end else if (accept) begin
      is_d_q       <= acc_is_d;
      is_sqrt_q    <= acc_is_sqrt;
      ill_q        <= acc_ill;
      spec_q       <= acc_spec;
      sgn_q        <= acc_sgn;
      rm_q         <= acc_rm;
      spec_res_q   <= acc_spec_res;
      spec_flg_q   <= acc_spec_flg;
      exp_q        <= acc_exp;
      iters_left_q <= acc_iters;
      rem_q        <= acc_rem;
      dvs_q        <= acc_dvs;
      quo_q        <= acc_quo;
    end else if (run && !spec_q && !ill_q && (iters_left_q != 5'd0)) begin
      iters_left_q <= iters_left_q - 5'd1;
      rem_q        <= run_rem;
      dvs_q        <= run_dvs;
      quo_q        <= run_quo;
    end
  end

  // ---- result rounding & packing (valid when complete) ----
  always_comb begin
    logic [54:0] sig55;   // [54]=1 (MSB), [53:2]=52-bit mantissa (S in [53:31]), [1]=guard, [0]=sticky
    logic        rem_nz;

    result  = 64'd0;
    fflags  = 5'd0;
    illegal = ill_q;
    rem_nz  = (rem_q != 58'd0);

    if (is_sqrt_q) begin
      // dvs_q[54:0] holds root scaled by 2^54 (55 bits: [54]=1, [53:2]=52b mant, [1]=g, [0]=s0)
      sig55 = {dvs_q[54:1], dvs_q[0] | rem_nz};
    end else if (is_d_q) begin
      // 18 * 3 = 54 bits shifted in after q0=1 -> quo_q[54]=1, [53:2]=52b mant, [1]=g, [0]=s0
      sig55 = {quo_q[54:1], quo_q[0] | rem_nz};
    end else begin
      // S div: 9 * 3 = 27 bits shifted in after q0=1 -> quo_q[27]=1, [26:4]=23b mant, [3]=g, [2:0]|rem_nz=s
      sig55 = {quo_q[27:4], 29'd0, quo_q[3], (|quo_q[2:0]) | rem_nz};
    end

    if (ill_q) begin
      result = 64'd0;
      fflags = 5'd0;
    end else if (spec_q) begin
      result = spec_res_q;
      fflags = spec_flg_q;
    end else if (is_d_q) begin
      logic signed [12:0] e_biased;
      e_biased = exp_q + 13'sd1023;
      if (e_biased >= 13'sd1) begin
        logic        g, s, rinc;
        logic [52:0] mant_inc;
        logic signed [12:0] e_out;
        g        = sig55[1];
        s        = sig55[0];
        rinc     = fp_round_inc(rm_q, sgn_q, sig55[2], g, s);
        mant_inc = {1'b0, sig55[53:2]} + {52'd0, rinc};
        e_out    = e_biased + {12'd0, mant_inc[52]};
        if (e_out >= 13'sd2047) begin
          logic max_fin;
          fflags[FLG_OF] = 1'b1;
          fflags[FLG_NX] = 1'b1;
          max_fin        = (rm_q == 3'd1) || (rm_q == 3'd2 && !sgn_q) || (rm_q == 3'd3 && sgn_q);
          result         = max_fin ? {sgn_q, 11'h7fe, 52'hffff_ffff_ffff_f} : {sgn_q, 11'h7ff, 52'd0};
        end else begin
          fflags[FLG_NX] = g | s;
          result         = {sgn_q, e_out[10:0], mant_inc[51:0]};
        end
      end else begin
        logic [12:0] rsh;
        logic [54:0] shifted, smask;
        logic        lost, g, s, rinc, tiny_after;
        logic [52:0] mant_inc;
        rsh = 13'd1 - e_biased;
        if (rsh >= 13'd55) begin
          shifted = 55'd0;
          g       = 1'b0;
          s       = 1'b1;
        end else begin
          shifted = sig55 >> rsh[5:0];
          smask   = (55'd1 << rsh[5:0]) - 55'd1;
          lost    = (sig55 & smask) != 55'd0;
          g       = shifted[1];
          s       = shifted[0] | lost;
        end
        rinc       = fp_round_inc(rm_q, sgn_q, shifted[2], g, s);
        mant_inc   = {1'b0, shifted[53:2]} + {52'd0, rinc};
        tiny_after = !((e_biased == 13'sd0) && (&sig55[53:2]) &&
                       fp_round_inc(rm_q, sgn_q, sig55[2], sig55[1], sig55[0]));
        fflags[FLG_NX] = g | s;
        fflags[FLG_UF] = (g | s) && tiny_after;
        result         = {sgn_q, 10'd0, mant_inc[52], mant_inc[51:0]};
      end
    end else begin
      // Single precision
      logic signed [12:0] e_biased;
      logic [25:0]        sig26;
      e_biased = exp_q + 13'sd127;
      if (is_sqrt_q) sig26 = {dvs_q[54:31], dvs_q[30], (|dvs_q[29:0]) | rem_nz};
      else           sig26 = {sig55[54:31], sig55[1], sig55[0]};
      if (e_biased >= 13'sd1) begin
        logic        g, s, rinc;
        logic [23:0] mant_inc;
        logic signed [12:0] e_out;
        g        = sig26[1];
        s        = sig26[0];
        rinc     = fp_round_inc(rm_q, sgn_q, sig26[2], g, s);
        mant_inc = {1'b0, sig26[24:2]} + {23'd0, rinc};
        e_out    = e_biased + {12'd0, mant_inc[23]};
        if (e_out >= 13'sd255) begin
          logic max_fin;
          fflags[FLG_OF] = 1'b1;
          fflags[FLG_NX] = 1'b1;
          max_fin        = (rm_q == 3'd1) || (rm_q == 3'd2 && !sgn_q) || (rm_q == 3'd3 && sgn_q);
          result         = fp_nanbox32(max_fin ? {sgn_q, 8'hfe, 23'h7fffff} : {sgn_q, 8'hff, 23'd0});
        end else begin
          fflags[FLG_NX] = g | s;
          result         = fp_nanbox32({sgn_q, e_out[7:0], mant_inc[22:0]});
        end
      end else begin
        logic [12:0] rsh;
        logic [25:0] shifted, smask;
        logic        lost, g, s, rinc, tiny_after;
        logic [23:0] mant_inc;
        rsh = 13'd1 - e_biased;
        if (rsh >= 13'd26) begin
          shifted = 26'd0;
          g       = 1'b0;
          s       = 1'b1;
        end else begin
          shifted = sig26 >> rsh[4:0];
          smask   = (26'd1 << rsh[4:0]) - 26'd1;
          lost    = (sig26 & smask) != 26'd0;
          g       = shifted[1];
          s       = shifted[0] | lost;
        end
        rinc       = fp_round_inc(rm_q, sgn_q, shifted[2], g, s);
        mant_inc   = {1'b0, shifted[24:2]} + {23'd0, rinc};
        tiny_after = !((e_biased == 13'sd0) && (&sig26[24:2]) &&
                       fp_round_inc(rm_q, sgn_q, sig26[2], sig26[1], sig26[0]));
        fflags[FLG_NX] = g | s;
        fflags[FLG_UF] = (g | s) && tiny_after;
        result         = fp_nanbox32({sgn_q, 7'd0, mant_inc[23], mant_inc[22:0]});
      end
    end
  end

endmodule
`default_nettype wire
