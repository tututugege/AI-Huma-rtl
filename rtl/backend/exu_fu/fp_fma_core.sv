// Synthesizable 3-stage pipelined RV64FD FMA core:
//   fmadd / fmsub / fnmsub / fnmadd / fadd / fsub / fmul (single & double precision).
// Latency = 3 cycles (accept at t, result valid at t+2, matching FP_FMA_LAT = 3).
// Bit-exact against Berkeley SoftFloat (verified by scripts/fp_synth_check.sh).
`default_nettype none
module fp_fma_core
  import ttg_cfg_pkg::*;
  import fp_arith_pkg::*;
(
  input  logic        clk,
  input  logic [2:0]  func3,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] imm,        // imm[16:12]=op5, imm[11:5]=funct7, imm[4:0]=rs2
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [63:0] fsrc1,
  input  logic [63:0] fsrc2,
  input  logic [63:0] fsrc3,
  input  logic [2:0]  frm,
  output logic [63:0] result,
  output logic [4:0]  fflags,
  output logic        illegal
);

  // =========================================================================
  // Stage 0 (cycle t): decode, reduce fadd/fsub/fmul -> FMA, unpack & norm
  // =========================================================================
  logic [4:0]  op5, funct5;
  logic [6:0]  funct7;
  logic [1:0]  fmt;
  logic        s0_is_d, s0_illegal;
  logic [2:0]  s0_rm;

  logic        s0_sa, s0_sb, s0_sc, s0_sp;
  logic signed [12:0] s0_ea, s0_eb, s0_ec;
  logic [52:0] s0_ma, s0_mb, s0_mc;
  logic        s0_az, s0_bz, s0_cz;
  logic        s0_spec;
  logic [63:0] s0_spec_res;
  logic [4:0]  s0_spec_flg;

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
      // Subnormal: normalize left so sig[52] == 1
      logic [6:0]  lz;
      logic [63:0] norm64;
      lz     = clz64({m_raw, 12'd0});   // 0..51
      norm64 = {m_raw, 12'd0} << lz[5:0];
      sig    = norm64[63:11];           // norm64[63] == 1
      e_unb  = (is_d ? -13'sd1023 : -13'sd127) - $signed({6'd0, lz});
    end else begin
      sig   = {1'b1, m_raw};
      e_unb = $signed({2'd0, e_raw}) - (is_d ? 13'sd1023 : 13'sd127);
    end
  endtask

  always_comb begin
    logic        is_fma_op, is_add, is_sub, is_mul;
    logic        neg_a, neg_c;
    logic [63:0] raw_a, raw_b, raw_c;
    logic        az, ai, an, asn, bz, bi, bn, bsn, cz, ci, cn, csn;
    logic        sp, prod_zero, prod_inf, inv_mul, inv_add;

    op5    = imm[16:12];
    funct7 = imm[11:5];
    fmt    = funct7[1:0];
    funct5 = funct7[6:2];
    s0_is_d = (fmt == 2'd1);
    s0_rm   = fp_resolve_rm(func3, frm);

    is_fma_op = (op5 >= 5'h10 && op5 <= 5'h13);
    is_add    = (op5 == 5'h14) && (funct5 == 5'h00);
    is_sub    = (op5 == 5'h14) && (funct5 == 5'h01);
    is_mul    = (op5 == 5'h14) && (funct5 == 5'h02);

    s0_illegal = (fmt > 2'd1) || !fp_rm_valid(s0_rm) || !(is_fma_op || is_add || is_sub || is_mul);

    neg_a = (op5 == 5'h12) || (op5 == 5'h13);
    neg_c = (op5 == 5'h11) || (op5 == 5'h13) || is_sub;

    // Reduce fadd/fsub -> a * 1.0 +/- b, fmul -> a * b + 0.0
    raw_a = fsrc1;
    raw_b = (is_add || is_sub) ? (s0_is_d ? 64'h3ff0_0000_0000_0000 : fp_nanbox32(32'h3f80_0000)) : fsrc2;
    raw_c = (is_add || is_sub) ? fsrc2 :
            is_mul             ? (s0_is_d ? 64'd0 : fp_nanbox32(32'd0)) :
                                 fsrc3;

    unpack_fp(s0_is_d, raw_a, s0_sa, s0_ea, s0_ma, az, ai, an, asn);
    unpack_fp(s0_is_d, raw_b, s0_sb, s0_eb, s0_mb, bz, bi, bn, bsn);
    unpack_fp(s0_is_d, raw_c, s0_sc, s0_ec, s0_mc, cz, ci, cn, csn);

    if (neg_a) s0_sa = ~s0_sa;
    if (neg_c) s0_sc = ~s0_sc;
    sp = s0_sa ^ s0_sb;
    // For fmul, set zero addend sign equal to product sign so +0/-0 follows exact IEEE fmul sign
    if (is_mul) s0_sc = sp;

    s0_sp = sp;
    s0_az = az;
    s0_bz = bz;
    s0_cz = cz;

    // Special-case resolution (NaN, 0*Inf, Inf-Inf, Inf, 0+0)
    prod_zero = az || bz;
    prod_inf  = (ai && !bz && !bn) || (bi && !az && !an);
    inv_mul   = (az && bi) || (bz && ai);
    inv_add   = prod_inf && ci && (sp != s0_sc);

    s0_spec     = 1'b0;
    s0_spec_res = 64'd0;
    s0_spec_flg = 5'd0;

    if (an || bn || cn || inv_mul || inv_add) begin
      s0_spec               = 1'b1;
      s0_spec_res           = s0_is_d ? CANON_NAN64 : fp_nanbox32(CANON_NAN32);
      s0_spec_flg[FLG_NV]   = asn || bsn || csn || inv_mul || inv_add;
    end else if (prod_inf) begin
      s0_spec     = 1'b1;
      s0_spec_res = s0_is_d ? {sp, 11'h7ff, 52'd0} : fp_nanbox32({sp, 8'hff, 23'd0});
    end else if (ci) begin
      s0_spec     = 1'b1;
      s0_spec_res = s0_is_d ? {s0_sc, 11'h7ff, 52'd0} : fp_nanbox32({s0_sc, 8'hff, 23'd0});
    end else if (prod_zero && cz) begin
      logic z_sgn;
      z_sgn       = (sp == s0_sc) ? sp : (s0_rm == 3'd2);
      s0_spec     = 1'b1;
      s0_spec_res = s0_is_d ? {z_sgn, 63'd0} : fp_nanbox32({z_sgn, 31'd0});
    end
  end

  // ---- Stage 0 -> Stage 1 registers ----
  logic        s1_is_d_q, s1_ill_q, s1_spec_q;
  logic [2:0]  s1_rm_q;
  logic [63:0] s1_spec_res_q;
  logic [4:0]  s1_spec_flg_q;
  logic        s1_sp_q, s1_sc_q, s1_pzero_q, s1_cz_q;
  logic signed [12:0] s1_ea_q, s1_eb_q, s1_ec_q;
  logic [52:0] s1_ma_q, s1_mb_q, s1_mc_q;

  always_ff @(posedge clk) begin
    s1_is_d_q     <= s0_is_d;
    s1_ill_q      <= s0_illegal;
    s1_spec_q     <= s0_spec;
    s1_rm_q       <= s0_rm;
    s1_spec_res_q <= s0_spec_res;
    s1_spec_flg_q <= s0_spec_flg;
    s1_sp_q       <= s0_sp;
    s1_sc_q       <= s0_sc;
    s1_pzero_q    <= s0_az || s0_bz;
    s1_cz_q       <= s0_cz;
    s1_ea_q       <= s0_ea;
    s1_eb_q       <= s0_eb;
    s1_ec_q       <= s0_ec;
    s1_ma_q       <= s0_ma;
    s1_mb_q       <= s0_mb;
    s1_mc_q       <= s0_mc;
  end

  // =========================================================================
  // Stage 1 (cycle t+1): 53x53 multiply, 163-bit align & add/sub
  // =========================================================================
  // Fixed-point accumulator width AW = 163 bits:
  //   prod (106 bits, bit 104 = 2^ep, bit 105 = 2^(ep+1)) is placed at bits [107:2]
  //   when c is shifted relative to prod:
  //     c_top_pos = 106 (represents 2^(ep+2)) .. 160 (represents 2^(ep+56))
  //   Anchor exponent e_top corresponds to MSB bit 162 = 2^(e_top).
  //   Specifically, when c_shift >= 0 (c shifted right relative to top):
  //     bit 162 has weight 2^(ep + 56), so prod[105:0] sits at [107:2] (bit 106 = 2^ep? Wait:
  //     162 - 56 = 106 -> bit 106 has weight 2^ep, bit 107 has weight 2^(ep+1), bit 2 has weight 2^(ep-104)!)
  //   Check: prod = ma * mb where ma[52]=2^0, mb[52]=2^0 -> prod[104] = 2^0 * 2^ep = 2^ep,
  //          prod[105] = 2^(ep+1), prod[0] = 2^(ep-104).
  //   So placing prod[105:0] at [107:2] puts:
  //     bit 107 = 2^(ep+1), bit 106 = 2^ep, ..., bit 2 = 2^(ep-104).
  //     Then bit 162 = 2^(ep+56)!
  //   Now where does mc[52:0] (where mc[52] has weight 2^ec) sit?
  //     mc[52] needs to sit at bit pos = 106 + (ec - ep) = 162 - (ep + 56 - ec).
  //     Let rsh_c = (ep + 56) - ec:
  //       - If rsh_c <= 0 (ec >= ep + 56): c dominates prod completely!
  //         Place mc[52:0] at [162:110] (so e_top = ec), prod collapses into sticky bit (unless prod_zero)!
  //       - If 0 < rsh_c < 163: place {mc, 110'd0} >> rsh_c, with shifted-out bits -> c_sticky; e_top = ep + 56.
  //       - If rsh_c >= 163: c collapses into c_sticky (unless cz); e_top = ep + 56.
  localparam int AW = 163;

  logic [AW-1:0]      s1_abs_sum;
  logic               s1_res_sgn, s1_sticky, s1_exact_zero;
  logic signed [12:0] s1_e_top;

  always_comb begin
    logic [105:0]       prod106;
    logic signed [12:0] ep, rsh_c;
    logic [AW-1:0]      p_aligned, c_aligned, big_v, small_v;
    logic               p_stk, c_stk, eff_sub, c_gt_p;
    logic [AW:0]        sum_raw;

    prod106 = s1_pzero_q ? 106'd0 : (106'(s1_ma_q) * 106'(s1_mb_q));
    ep      = s1_ea_q + s1_eb_q;
    eff_sub = s1_sp_q ^ s1_sc_q;

    p_stk   = 1'b0;
    c_stk   = 1'b0;

    if (s1_cz_q) begin
      // c == 0: result is just prod
      s1_e_top  = ep + 13'sd56;
      p_aligned = {55'd0, prod106, 2'd0};
      c_aligned = '0;
    end else if (s1_pzero_q) begin
      // prod == 0: result is just c
      s1_e_top  = s1_ec_q;
      p_aligned = '0;
      c_aligned = {s1_mc_q, 110'd0};
    end else begin
      rsh_c = (ep + 13'sd56) - s1_ec_q;
      if (rsh_c <= 13'sd0) begin
        // c >= 2^(ep+56): prod is strictly below bit 108, collapses into p_stk
        s1_e_top  = s1_ec_q;
        c_aligned = {s1_mc_q, 110'd0};
        p_aligned = '0;
        p_stk     = 1'b1;   // prod != 0 since !s1_pzero_q
      end else if (rsh_c >= 13'sd163) begin
        // c is completely below bit 0 of accumulator
        s1_e_top  = ep + 13'sd56;
        p_aligned = {55'd0, prod106, 2'd0};
        c_aligned = '0;
        c_stk     = 1'b1;   // c != 0 since !s1_cz_q
      end else begin
        logic [AW-1:0] c_full, c_mask;
        s1_e_top  = ep + 13'sd56;
        p_aligned = {55'd0, prod106, 2'd0};
        c_full    = {s1_mc_q, 110'd0};
        c_aligned = c_full >> rsh_c[7:0];
        c_mask    = (AW'(1) << rsh_c[7:0]) - AW'(1);
        c_stk     = (c_full & c_mask) != '0;
      end
    end

    // Add or subtract magnitudes (including sticky bit at position -1!)
    // Exact value of p = (p_aligned, p_stk), c = (c_aligned, c_stk) where at most one of p_stk, c_stk is 1.
    if (!eff_sub) begin
      sum_raw       = {1'b0, p_aligned} + {1'b0, c_aligned};
      // Note: sum_raw[AW] is 0 because p_aligned[162:108]==0 when rsh_c>0, and p_aligned==0 when rsh_c<=0.
      s1_abs_sum    = sum_raw[AW-1:0];
      s1_res_sgn    = s1_cz_q ? s1_sp_q : (s1_pzero_q ? s1_sc_q : s1_sp_q);
      s1_sticky     = p_stk | c_stk;
      s1_exact_zero = (s1_abs_sum == '0) && !s1_sticky;
    end else begin
      // Compare (c_aligned, c_stk) > (p_aligned, p_stk)
      c_gt_p = (c_aligned > p_aligned) || ((c_aligned == p_aligned) && c_stk && !p_stk);
      if (c_gt_p) begin
        big_v      = c_aligned;
        small_v    = p_aligned;
        s1_res_sgn = s1_sc_q;
        // (big_v + c_stk*eps) - (small_v + p_stk*eps):
        // if p_stk==1 (and c_stk==0), borrow 1 from LSB and set sticky=1
        s1_abs_sum = big_v - small_v - {{(AW-1){1'b0}}, p_stk};
        s1_sticky  = p_stk | c_stk;
      end else begin
        big_v      = p_aligned;
        small_v    = c_aligned;
        s1_res_sgn = s1_sp_q;
        s1_abs_sum = big_v - small_v - {{(AW-1){1'b0}}, c_stk};
        s1_sticky  = p_stk | c_stk;
      end
      s1_exact_zero = (s1_abs_sum == '0) && !s1_sticky;
      if (s1_exact_zero) s1_res_sgn = (s1_rm_q == 3'd2);   // exact cancellation: -0.0 iff RDN
    end
  end

  // ---- Stage 1 -> Stage 2 registers ----
  logic               s2_is_d_q, s2_ill_q, s2_spec_q;
  logic [2:0]         s2_rm_q;
  logic [63:0]        s2_spec_res_q;
  logic [4:0]         s2_spec_flg_q;
  logic [AW-1:0]      s2_abs_sum_q;
  logic               s2_res_sgn_q, s2_sticky_q, s2_exact_zero_q;
  logic signed [12:0] s2_e_top_q;

  always_ff @(posedge clk) begin
    s2_is_d_q       <= s1_is_d_q;
    s2_ill_q        <= s1_ill_q;
    s2_spec_q       <= s1_spec_q;
    s2_rm_q         <= s1_rm_q;
    s2_spec_res_q   <= s1_spec_res_q;
    s2_spec_flg_q   <= s1_spec_flg_q;
    s2_abs_sum_q    <= s1_abs_sum;
    s2_res_sgn_q    <= s1_res_sgn;
    s2_sticky_q     <= s1_sticky;
    s2_exact_zero_q <= s1_exact_zero;
    s2_e_top_q      <= s1_e_top;
  end

  // =========================================================================
  // Stage 2 (cycle t+2): CLZ normalize, subnormal shift, IEEE-754 round & pack
  // =========================================================================
  always_comb begin
    logic [6:0]         lz_hi, lz_mid, lz_lo;
    logic [7:0]         lz;
    logic [AW-1:0]      norm;
    logic signed [12:0] e_unb, e_biased;

    result  = 64'd0;
    fflags  = 5'd0;
    illegal = s2_ill_q;

    // 163-bit CLZ via 3 parallel 64-bit CLZ trees
    lz_hi  = clz64(s2_abs_sum_q[162:99]);
    lz_mid = clz64(s2_abs_sum_q[98:35]);
    lz_lo  = clz64({s2_abs_sum_q[34:0], 29'd0});
    if (lz_hi != 7'd64)       lz = {1'b0, lz_hi};
    else if (lz_mid != 7'd64) lz = 8'd64  + {1'b0, lz_mid};
    else                      lz = 8'd128 + {1'b0, lz_lo};

    norm  = s2_abs_sum_q << lz;   // norm[162] == 1 when s2_abs_sum_q != 0
    e_unb = s2_e_top_q - $signed({5'd0, lz});

    if (s2_ill_q) begin
      result = 64'd0;
      fflags = 5'd0;
    end else if (s2_spec_q) begin
      result = s2_spec_res_q;
      fflags = s2_spec_flg_q;
    end else if (s2_exact_zero_q) begin
      result = s2_is_d_q ? {s2_res_sgn_q, 63'd0} : fp_nanbox32({s2_res_sgn_q, 31'd0});
      fflags = 5'd0;
    end else if (s2_is_d_q) begin
      // ---- Double precision rounding & packing ----
      e_biased = e_unb + 13'sd1023;
      if (e_biased >= 13'sd1) begin
        logic        g, s, rinc;
        logic [52:0] mant_inc;
        logic signed [12:0] e_out;
        // norm[162]=1, norm[161:110]=52-bit mantissa, norm[109]=g, |norm[108:0]|s2_sticky=s
        g        = norm[109];
        s        = (|norm[108:0]) | s2_sticky_q;
        rinc     = fp_round_inc(s2_rm_q, s2_res_sgn_q, norm[110], g, s);
        mant_inc = {1'b0, norm[161:110]} + {52'd0, rinc};
        e_out    = e_biased + {12'd0, mant_inc[52]};
        if (e_out >= 13'sd2047) begin
          logic max_fin;
          fflags[FLG_OF] = 1'b1;
          fflags[FLG_NX] = 1'b1;
          max_fin        = (s2_rm_q == 3'd1) || (s2_rm_q == 3'd2 && !s2_res_sgn_q) || (s2_rm_q == 3'd3 && s2_res_sgn_q);
          result         = max_fin ? {s2_res_sgn_q, 11'h7fe, 52'hffff_ffff_ffff_f} : {s2_res_sgn_q, 11'h7ff, 52'd0};
        end else begin
          fflags[FLG_NX] = g | s;
          result         = {s2_res_sgn_q, e_out[10:0], mant_inc[51:0]};
        end
      end else begin
        // Double subnormal / underflow
        logic [12:0] rsh;
        logic [54:0] sig55, shifted, smask;
        logic        lost, g, s, rinc, tiny_after;
        logic [52:0] mant_inc;
        rsh   = 13'd1 - e_biased;
        // Pack 53-bit significand + 2 low bits (guard + sticky) into 55 bits before right shift
        sig55 = {norm[162:110], norm[109], (|norm[108:0]) | s2_sticky_q};
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
        rinc       = fp_round_inc(s2_rm_q, s2_res_sgn_q, shifted[2], g, s);
        mant_inc   = {1'b0, shifted[53:2]} + {52'd0, rinc};
        tiny_after = !((e_biased == 13'sd0) && (&norm[161:110]) &&
                       fp_round_inc(s2_rm_q, s2_res_sgn_q, norm[110], norm[109], (|norm[108:0]) | s2_sticky_q));
        fflags[FLG_NX] = g | s;
        fflags[FLG_UF] = (g | s) && tiny_after;
        result         = {s2_res_sgn_q, 10'd0, mant_inc[52], mant_inc[51:0]};
      end
    end else begin
      // ---- Single precision rounding & packing ----
      e_biased = e_unb + 13'sd127;
      if (e_biased >= 13'sd1) begin
        logic        g, s, rinc;
        logic [23:0] mant_inc;
        logic signed [12:0] e_out;
        // norm[162]=1, norm[161:139]=23-bit mantissa, norm[138]=g, |norm[137:0]|s2_sticky=s
        g        = norm[138];
        s        = (|norm[137:0]) | s2_sticky_q;
        rinc     = fp_round_inc(s2_rm_q, s2_res_sgn_q, norm[139], g, s);
        mant_inc = {1'b0, norm[161:139]} + {23'd0, rinc};
        e_out    = e_biased + {12'd0, mant_inc[23]};
        if (e_out >= 13'sd255) begin
          logic max_fin;
          fflags[FLG_OF] = 1'b1;
          fflags[FLG_NX] = 1'b1;
          max_fin        = (s2_rm_q == 3'd1) || (s2_rm_q == 3'd2 && !s2_res_sgn_q) || (s2_rm_q == 3'd3 && s2_res_sgn_q);
          result         = fp_nanbox32(max_fin ? {s2_res_sgn_q, 8'hfe, 23'h7fffff} : {s2_res_sgn_q, 8'hff, 23'd0});
        end else begin
          fflags[FLG_NX] = g | s;
          result         = fp_nanbox32({s2_res_sgn_q, e_out[7:0], mant_inc[22:0]});
        end
      end else begin
        // Single subnormal / underflow
        logic [12:0] rsh;
        logic [25:0] sig26, shifted, smask;
        logic        lost, g, s, rinc, tiny_after;
        logic [23:0] mant_inc;
        rsh   = 13'd1 - e_biased;
        sig26 = {norm[162:139], norm[138], (|norm[137:0]) | s2_sticky_q};
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
        rinc       = fp_round_inc(s2_rm_q, s2_res_sgn_q, shifted[2], g, s);
        mant_inc   = {1'b0, shifted[24:2]} + {23'd0, rinc};
        tiny_after = !((e_biased == 13'sd0) && (&norm[161:139]) &&
                       fp_round_inc(s2_rm_q, s2_res_sgn_q, norm[139], norm[138], (|norm[137:0]) | s2_sticky_q));
        fflags[FLG_NX] = g | s;
        fflags[FLG_UF] = (g | s) && tiny_after;
        result         = fp_nanbox32({s2_res_sgn_q, 7'd0, mant_inc[23], mant_inc[22:0]});
      end
    end
  end

endmodule
`default_nettype wire
