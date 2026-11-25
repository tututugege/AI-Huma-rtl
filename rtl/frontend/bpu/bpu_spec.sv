// Ref: front-end/BPU/BPU_pipe.h  State::spec / arch / sras / aras (1024-bit history ring & RAS, 2-taken S0 A+B)
`default_nettype none

module bpu_spec import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // commit stream (architectural copies)
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  upd_is_rvc,
  input  logic [XLEN_BITS-1:0]         target   [NCOMMIT],
  // step-1 speculative update command (0..2 symbols, 0..2 RAS ops)
  input  logic [1:0]          h_mode,
  input  hist_ck_t            h_ck,
  input  logic [1:0]          h_push_n,
  input  logic [5:0]          h_push_bits,
  input  logic [1:0]          r_mode,
  input  ras_ck_t             r_ck,
  input  logic [1:0]          r_op,
  input  logic [XLEN_BITS-1:0]         r_val,
  input  logic [1:0]          r_op2,
  input  logic [XLEN_BITS-1:0]         r_val2,
  // step-2: S0 Block A push on refetch / BFANY
  input  logic                h2_en,
  input  logic [HSYM_W-1:0]   h2_bits,
  input  logic [1:0]          r2_op,
  input  logic [XLEN_BITS-1:0]         r2_val,
  // step-3: S0 Block B push when paired
  input  logic                h3_en,
  input  logic [HSYM_W-1:0]   h3_bits,
  input  logic [1:0]          r3_op,
  input  logic [XLEN_BITS-1:0]         r3_val,
  // state before this cycle's update (S0 A view when !refetch)
  output ck_t                 spec_ck,
  output logic                spec_ras_nonempty,
  output logic [XLEN_BITS-1:0]         spec_ras_top,
  output fh_t                 spec_fh,
  // state after refetch/command step 1, before S0 A (S0 A view when refetch)
  output ck_t                 spec1_ck,
  output logic                spec1_ras_nonempty,
  output logic [XLEN_BITS-1:0]         spec1_ras_top,
  output fh_t                 spec1_fh,
  // state after S0 Block A push, before S0 Block B (S0 B view & ck_b)
  output ck_t                 spec_a_ck,
  output logic                spec_a_ras_nonempty,
  output logic [XLEN_BITS-1:0]         spec_a_ras_top,
  output fh_t                 spec_a_fh,
  // REFONLY: refetch flag, issue flag, direct S0 Block A inputs (independent of S2 ovr), and refetch-only step-1 command
  input  logic                refetch,
  input  logic                issue,
  input  logic                g0_h_en,
  input  logic [HSYM_W-1:0]   g0_h_bits,
  input  logic [1:0]          g0_r_op,
  input  logic [XLEN_BITS-1:0] g0_r_val,
  input  logic [1:0]          hr_mode,
  input  hist_ck_t            hr_ck,
  input  logic [1:0]          hr_push_n,
  input  logic [5:0]          hr_push_bits,
  input  logic [1:0]          rr_mode,
  input  ras_ck_t             rr_ck,
  input  logic [1:0]          rr_op,
  input  logic [XLEN_BITS-1:0]         rr_val,
  input  logic [1:0]          rr_op2,
  input  logic [XLEN_BITS-1:0]         rr_val2,
  // IMLI 2-bit ops & checkpoints
  input  logic [1:0]          i1_op,
  input  logic [7:0]          i_ck,
  input  logic [1:0]          i2_op,
  input  logic [1:0]          i3_op,
  input  logic [1:0]          ir1_op,
  input  logic [7:0]          ir_ck,
  input  logic [1:0]          g0_i_op
);

  localparam bit FAST    = (FE_RFAST & 1) != 0 || FE_BFAST != 0;
  localparam bit BFANY   = (FE_BFAST & 3) != 0;
  localparam bit REFONLY = FAST && !BFANY;

  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  /* verilator lint_off UNUSEDSIGNAL */
  hist_t spec_d1, spec_da;
  /* verilator lint_on UNUSEDSIGNAL */
  hist_t spec_q, spec_d;
  // Architectural history never rolls back: 720-bit linear shift register (bit 0 = newest) + folded histories
  // Covers EX_GHR_LEN[7] = 712 with zero circular barrel shifter on M_ARCH critical path (100% bit-exact)
  localparam int ARCH_SR_W = 720;
  logic [ARCH_SR_W-1:0] arch_sr_q, arch_sr_d;
  fh_t                  arch_fh_q, arch_fh_d;
  ex_fh_t               arch_ex_fh_q, arch_ex_fh_d;
  sc_fh_t               arch_sc_fh_q, arch_sc_fh_d;
  logic [7:0]           arch_imli_q, arch_imli_d;
  logic [7:0]           spec_imli_q, spec_imli_d1, spec_imli_da, spec_imli_d;
  rasc_t aras_q, aras_d;
  logic [XLEN_BITS-1:0] st_q  [RASQ_N];
  logic [RASQ_W-1:0]    nos_q [RASQ_N];
  rptr_t                rp_q;

  // Ref: push_arch: every taken control instruction of the commit lanes pushes its symbol
  logic [23:0] arch_d_bits;
  logic [3:0]  arch_sym_n;

  always_comb begin
    logic [2:0] hs_t;
    arch_d_bits = '0;
    arch_sym_n  = '0;
    arch_imli_d = arch_imli_q;
    hs_t        = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      hs_t = hsym_of(base_pc[i], target[i]);
      if (upd_valid[i]) begin
        arch_imli_d = imli_apply(arch_imli_d, imli_op_of(br_type[i], actual_dir[i], base_pc[i], target[i], 1'b0));
      end
      if (upd_valid[i] && (br_type[i] != BR_NONCTL) && actual_dir[i]) begin
        arch_d_bits = {arch_d_bits[20:0], hs_t[0], hs_t[1], hs_t[2]};
        arch_sym_n  = arch_sym_n + 4'd1;
      end
    end
  end

  // Linear 128-bit architectural history push (0..12 symbols, zero circular barrel shifter)
  function automatic logic [FH_W-1:0] arch_rotl_const(input logic [FH_W-1:0] x, input int unsigned a, input int unsigned len);
    logic [FH_W-1:0] msk;
    msk = FH_W'((32'd1 << len) - 32'd1);
    return (a == 0) ? x : (((x << a) | (x >> (len - a))) & msk);
  endfunction

  function automatic logic [FH_W-1:0] arch_rotl_sym(input logic [FH_W-1:0] x, input logic [3:0] sn, input int unsigned len);
    case (sn)
      4'd1:    return arch_rotl_const(x,  3 % len, len);
      4'd2:    return arch_rotl_const(x,  6 % len, len);
      4'd3:    return arch_rotl_const(x,  9 % len, len);
      4'd4:    return arch_rotl_const(x, 12 % len, len);
      4'd5:    return arch_rotl_const(x, 15 % len, len);
      4'd6:    return arch_rotl_const(x, 18 % len, len);
      4'd7:    return arch_rotl_const(x, 21 % len, len);
      4'd8:    return arch_rotl_const(x, 24 % len, len);
      4'd9:    return arch_rotl_const(x, 27 % len, len);
      4'd10:   return arch_rotl_const(x, 30 % len, len);
      4'd11:   return arch_rotl_const(x, 33 % len, len);
      4'd12:   return arch_rotl_const(x, 36 % len, len);
      default: return x;
    endcase
  endfunction

  function automatic logic [EX_FH_W-1:0] arch_rotl_const_ex(input logic [EX_FH_W-1:0] x, input int unsigned a,
                                                            input int unsigned len);
    logic [EX_FH_W-1:0] msk;
    msk = EX_FH_W'((32'd1 << len) - 32'd1);
    return (a == 0) ? x : (((x << a) | (x >> (len - a))) & msk);
  endfunction

  function automatic logic [EX_FH_W-1:0] arch_rotl_sym_ex(input logic [EX_FH_W-1:0] x, input logic [3:0] sn,
                                                          input int unsigned len);
    case (sn)
      4'd1:    return arch_rotl_const_ex(x,  3 % len, len);
      4'd2:    return arch_rotl_const_ex(x,  6 % len, len);
      4'd3:    return arch_rotl_const_ex(x,  9 % len, len);
      4'd4:    return arch_rotl_const_ex(x, 12 % len, len);
      4'd5:    return arch_rotl_const_ex(x, 15 % len, len);
      4'd6:    return arch_rotl_const_ex(x, 18 % len, len);
      4'd7:    return arch_rotl_const_ex(x, 21 % len, len);
      4'd8:    return arch_rotl_const_ex(x, 24 % len, len);
      4'd9:    return arch_rotl_const_ex(x, 27 % len, len);
      4'd10:   return arch_rotl_const_ex(x, 30 % len, len);
      4'd11:   return arch_rotl_const_ex(x, 33 % len, len);
      4'd12:   return arch_rotl_const_ex(x, 36 % len, len);
      default: return x;
    endcase
  endfunction

  function automatic logic [SC_FH_W-1:0] arch_rotl_const_sc(input logic [SC_FH_W-1:0] x, input int unsigned a);
    return (a == 0) ? x : ((x << a) | (x >> (SC_FH_W - a)));
  endfunction

  function automatic logic [SC_FH_W-1:0] arch_rotl_sym_sc(input logic [SC_FH_W-1:0] x, input logic [3:0] sn);
    case (sn)
      4'd1:    return arch_rotl_const_sc(x, 3);
      4'd2:    return arch_rotl_const_sc(x, 6);
      4'd3:    return x;
      4'd4:    return arch_rotl_const_sc(x, 3);
      4'd5:    return arch_rotl_const_sc(x, 6);
      4'd6:    return x;
      4'd7:    return arch_rotl_const_sc(x, 3);
      4'd8:    return arch_rotl_const_sc(x, 6);
      4'd9:    return x;
      4'd10:   return arch_rotl_const_sc(x, 3);
      4'd11:   return arch_rotl_const_sc(x, 6);
      4'd12:   return x;
      default: return x;
    endcase
  endfunction

  typedef struct packed {
    logic [ARCH_SR_W-1:0] sr;
    fh_t                  fh;
    ex_fh_t               ex_fh;
    sc_fh_t               sc_fh;
  } arch_hist_t;

  function automatic arch_hist_t arch_push_vec(input logic [ARCH_SR_W-1:0] sr,
                                               input fh_t fh, input ex_fh_t ex_fh, input sc_fh_t sc_fh,
                                               input logic [3:0] sn, input logic [35:0] d);
    arch_hist_t res;
    logic [5:0]  nb;
    logic [35:0] keep, din, din_of;
    logic [35:0] outw [TN];
    logic [35:0] ex_outw [EX_TN];
    logic [35:0] sc_outw [SC_GEHL_N];
    nb = {2'b0, sn} + {1'b0, sn, 1'b0}; // 3 * sn (0..36)
    for (int u = 0; u < 36; u++) begin
      keep[u] = (6'(u) < nb);
      din[u]  = d[u] && keep[u];
    end
    din_of = '0;
    for (int c = 1; c <= 12; c++) begin
      if (sn == 4'(c)) begin
        for (int j = 0; j < 3 * c; j++) din_of[j] = d[3 * c - 1 - j];
      end
    end
    res.sr = (sr << nb) | {{(ARCH_SR_W - 36){1'b0}}, din};
    for (int i = 0; i < TN; i++) begin
      logic [35:0] raw_o;
      raw_o = '0;
      for (int j = 0; j < 36; j++) begin
        if (j < ghr_len(i)) raw_o[j] = sr[ghr_len(i) - 1 - j];
        else                raw_o[j] = din_of[j - ghr_len(i)];
      end
      outw[i] = '0;
      for (int c = 1; c <= 12; c++) begin
        if (sn == 4'(c)) begin
          for (int u = 0; u < 3 * c; u++) outw[i][u] = raw_o[3 * c - 1 - u];
        end
      end
    end
    for (int i = 0; i < EX_TN; i++) begin
      logic [35:0] raw_o;
      raw_o = '0;
      for (int j = 0; j < 36; j++) begin
        if (j < ex_ghr_len(i)) raw_o[j] = sr[ex_ghr_len(i) - 1 - j];
        else                   raw_o[j] = din_of[j - ex_ghr_len(i)];
      end
      ex_outw[i] = '0;
      for (int c = 1; c <= 12; c++) begin
        if (sn == 4'(c)) begin
          for (int u = 0; u < 3 * c; u++) ex_outw[i][u] = raw_o[3 * c - 1 - u];
        end
      end
    end
    for (int g = 0; g < SC_GEHL_N; g++) begin
      logic [35:0] raw_o;
      raw_o = '0;
      for (int j = 0; j < 36; j++) begin
        if (j < sc_ghr_len(g)) raw_o[j] = sr[sc_ghr_len(g) - 1 - j];
        else                   raw_o[j] = din_of[j - sc_ghr_len(g)];
      end
      sc_outw[g] = '0;
      for (int c = 1; c <= 12; c++) begin
        if (sn == 4'(c)) begin
          for (int u = 0; u < 3 * c; u++) sc_outw[g][u] = raw_o[3 * c - 1 - u];
        end
      end
    end
    for (int k = 0; k < FH_K; k++) begin
      for (int i = 0; i < TN; i++) begin
        logic [FH_W-1:0] acc;
        acc = arch_rotl_sym(fh[k][i], sn, fh_len(k, i));
        for (int u = 0; u < 36; u++) begin
          acc = acc ^ arch_rotl_const(FH_W'(din[u]) ^ (FH_W'(outw[i][u]) << (ghr_len(i) % fh_len(k, i))),
                                      u % fh_len(k, i), fh_len(k, i));
        end
        res.fh[k][i] = acc;
      end
    end
    for (int k = 0; k < EX_FH_K; k++) begin
      for (int i = 0; i < EX_TN; i++) begin
        logic [EX_FH_W-1:0] acc;
        acc = arch_rotl_sym_ex(ex_fh[k][i], sn, ex_fh_len(k));
        for (int u = 0; u < 36; u++) begin
          acc = acc ^ arch_rotl_const_ex(EX_FH_W'(din[u]) ^ (EX_FH_W'(ex_outw[i][u]) << (ex_ghr_len(i) % ex_fh_len(k))),
                                         u % ex_fh_len(k), ex_fh_len(k));
        end
        res.ex_fh[k][i] = acc;
      end
    end
    for (int g = 0; g < SC_GEHL_N; g++) begin
      logic [SC_FH_W-1:0] acc;
      acc = arch_rotl_sym_sc(sc_fh[g], sn);
      for (int u = 0; u < 36; u++) begin
        acc = acc ^ arch_rotl_const_sc(SC_FH_W'(din[u]) ^ (SC_FH_W'(sc_outw[g][u]) << (sc_ghr_len(g) % SC_FH_W)),
                                       u % SC_FH_W);
      end
      res.sc_fh[g] = acc;
    end
    return res;
  endfunction

  function automatic hist_t arch_to_hist(input arch_hist_t a, input logic [3:0] extra_bits);
    hist_t h;
    h       = '0;
    h.head  = HR_PTR_W'(extra_bits);
    h.fh    = a.fh;
    h.ex_fh = a.ex_fh;
    h.sc_fh = a.sc_fh;
    for (int k = 0; k < ARCH_SR_W; k++) begin
      h.ring[HR_PTR_W'(extra_bits) - HR_PTR_W'(1) - HR_PTR_W'(k)] = a.sr[k];
    end
    return h;
  endfunction

  arch_hist_t arch_next_st;
  always_comb begin
    arch_next_st = arch_push_vec(arch_sr_q, arch_fh_q, arch_ex_fh_q, arch_sc_fh_q, arch_sym_n, {12'b0, arch_d_bits});
    arch_sr_d    = arch_next_st.sr;
    arch_fh_d    = arch_next_st.fh;
    arch_ex_fh_d = arch_next_st.ex_fh;
    arch_sc_fh_d = arch_next_st.sc_fh;
  end

  // Ref: commit loop: calls / returns move the architectural RAS
  // Parallel 3-level associative clamped-counter prefix (bit-exact to NCOMMIT serial ras_push/ras_pop calls)
  typedef struct packed {
    logic signed [4:0] d;     // net delta in [-8..+8]
    logic [RAS_CNT_W-1:0] lo; // clamped lower bound [0..RAS_DEPTH]
    logic [RAS_CNT_W-1:0] hi; // clamped upper bound [0..RAS_DEPTH]
  } ras_op_t;

  function automatic logic [RAS_CNT_W-1:0] ras_clamp_add(input logic [RAS_CNT_W-1:0] x, input logic signed [4:0] d,
                                                         input logic [RAS_CNT_W-1:0] lo, input logic [RAS_CNT_W-1:0] hi);
    logic signed [RAS_CNT_W+1:0] s;
    s = $signed({2'b00, x}) + $signed({{(RAS_CNT_W-3){d[4]}}, d});
    if (s < $signed({2'b00, lo}))      return lo;
    else if (s > $signed({2'b00, hi})) return hi;
    else                               return s[RAS_CNT_W-1:0];
  endfunction

  function automatic ras_op_t ras_compose(input ras_op_t a, input ras_op_t b);
    ras_op_t c;
    c.d  = a.d + b.d;
    c.lo = ras_clamp_add(a.lo, b.d, b.lo, b.hi);
    c.hi = ras_clamp_add(a.hi, b.d, b.lo, b.hi);
    return c;
  endfunction

  logic [NCOMMIT-1:0]   c_push;
  logic [XLEN_BITS-1:0] c_val [NCOMMIT];
  logic [RAS_PTR_W-1:0] ptr_after [NCOMMIT];

  always_comb begin
    logic [NCOMMIT-1:0]   c_pop, c_eff_pop;
    ras_op_t              p0 [NCOMMIT], p1 [NCOMMIT], p2 [NCOMMIT], p3 [NCOMMIT];
    logic [RAS_CNT_W-1:0] cnt_before [NCOMMIT];

    for (int i = 0; i < NCOMMIT; i++) begin
      c_push[i] = upd_valid[i] && (br_type[i] == BR_CALL || br_type[i] == BR_ICALL);
      c_pop[i]  = upd_valid[i] && (br_type[i] == BR_RET);
      c_val[i]  = base_pc[i] + (upd_is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4));
      if (c_push[i])      p0[i] = '{d:  5'sd1, lo: RAS_CNT_W'(1), hi: RAS_CNT_W'(RAS_DEPTH)};
      else if (c_pop[i])  p0[i] = '{d: -5'sd1, lo: RAS_CNT_W'(0), hi: RAS_CNT_W'(RAS_DEPTH - 1)};
      else                p0[i] = '{d:  5'sd0, lo: RAS_CNT_W'(0), hi: RAS_CNT_W'(RAS_DEPTH)};
    end

    // 3-level Kogge-Stone prefix over NCOMMIT=8 lanes
    for (int i = 0; i < NCOMMIT; i++) p1[i] = (i >= 1) ? ras_compose(p0[i-1], p0[i]) : p0[i];
    for (int i = 0; i < NCOMMIT; i++) p2[i] = (i >= 2) ? ras_compose(p1[i-2], p1[i]) : p1[i];
    for (int i = 0; i < NCOMMIT; i++) p3[i] = (i >= 4) ? ras_compose(p2[i-4], p2[i]) : p2[i];

    cnt_before[0] = aras_q.cnt;
    for (int i = 1; i < NCOMMIT; i++) begin
      cnt_before[i] = ras_clamp_add(aras_q.cnt, p3[i-1].d, p3[i-1].lo, p3[i-1].hi);
    end
    for (int i = 0; i < NCOMMIT; i++) begin
      c_eff_pop[i] = c_pop[i] && (cnt_before[i] != '0);
    end

    // Parallel 3-level prefix delta for ptr_after (net = push - eff_pop per lane)
    begin
      logic signed [4:0] d0 [NCOMMIT], d1 [NCOMMIT], d2 [NCOMMIT], d3 [NCOMMIT];
      for (int i = 0; i < NCOMMIT; i++) d0[i] = c_push[i] ? 5'sd1 : (c_eff_pop[i] ? -5'sd1 : 5'sd0);
      for (int i = 0; i < NCOMMIT; i++) d1[i] = (i >= 1) ? (d0[i-1] + d0[i]) : d0[i];
      for (int i = 0; i < NCOMMIT; i++) d2[i] = (i >= 2) ? (d1[i-2] + d1[i]) : d1[i];
      for (int i = 0; i < NCOMMIT; i++) d3[i] = (i >= 4) ? (d2[i-4] + d2[i]) : d2[i];
      for (int i = 0; i < NCOMMIT; i++) ptr_after[i] = aras_q.ptr + RAS_PTR_W'(d3[i]);
    end

    aras_d.cnt = ras_clamp_add(aras_q.cnt, p3[NCOMMIT-1].d, p3[NCOMMIT-1].lo, p3[NCOMMIT-1].hi);
    aras_d.ptr = ptr_after[NCOMMIT-1];
    for (int e = 0; e < RAS_DEPTH; e++) begin
      aras_d.st[e] = aras_q.st[e];
      for (int i = 0; i < NCOMMIT; i++) begin
        if (c_push[i] && (ptr_after[i] == RAS_PTR_W'(e))) aras_d.st[e] = c_val[i];
      end
    end
  end

  // Pack up to 4 sequential 3-bit symbols (oldest first: n1 of b1[5:0], then en2/b2, then en3/b3) into newest-first 24b
  function automatic logic [23:0] pack_syms(input logic [1:0] n1, input logic [5:0] b1,
                                            input logic en2, input logic [2:0] b2,
                                            input logic en3, input logic [2:0] b3);
    logic [23:0] d;
    d = '0;
    if (n1 >= 2'd1) d = {d[20:0], b1[0], b1[1], b1[2]};
    if (n1 >= 2'd2) d = {d[20:0], b1[3], b1[4], b1[5]};
    if (en2)        d = {d[20:0], b2[0], b2[1], b2[2]};
    if (en3)        d = {d[20:0], b3[0], b3[1], b3[2]};
    return d;
  endfunction

  function automatic logic [3:0] cnt_syms(input logic [1:0] n1, input logic en2, input logic en3);
    return 4'(int'(n1) + int'(en2) + int'(en3));
  endfunction

  // Concatenate arch_d_bits (older, arch_sym_n symbols) + extra symbols (newer, up to 4 symbols) into 36-bit vector
  function automatic logic [35:0] pack_arch_syms(input logic [23:0] abits,
                                                 input logic [1:0] n1, input logic [5:0] b1,
                                                 input logic en2, input logic [2:0] b2,
                                                 input logic en3, input logic [2:0] b3);
    logic [35:0] d;
    d = {12'b0, abits};
    if (n1 >= 2'd1) d = {d[32:0], b1[0], b1[1], b1[2]};
    if (n1 >= 2'd2) d = {d[32:0], b1[3], b1[4], b1[5]};
    if (en2)        d = {d[32:0], b2[0], b2[1], b2[2]};
    if (en3)        d = {d[32:0], b3[0], b3[1], b3[2]};
    return d;
  endfunction

  // Ref: comb: spec history update
  /* verilator lint_off UNUSEDSIGNAL */
  hist_t base1;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0] n1_eff;
  // M_ARCH restores from REGISTERED arch_sr_q / arch_fh_q / aras_q (breaks commit -> spec_d/spec_a_ras_top critical path)
  always_comb begin
    base1 = spec_q;
    case (h_mode)
      M_CK:    base1 = hist_restore(spec_q, h_ck);
      M_ARCH:  base1 = arch_to_hist('{sr: arch_sr_q, fh: arch_fh_q, ex_fh: arch_ex_fh_q, sc_fh: arch_sc_fh_q}, 4'd0);
      default: base1 = spec_q;
    endcase
    n1_eff = (h_mode != 2'd0) ? h_push_n : 2'd0;
  end

  if (!FAST) begin : g_h_old
    bpu_hist_vec #(.MAX_SYM(4)) u_v1 (.h(base1), .sym_n(cnt_syms(n1_eff, 1'b0, 1'b0)),
                       .d(pack_syms(n1_eff, h_push_bits, 1'b0, '0, 1'b0, '0)), .h_next(spec_d1));
    bpu_hist_vec #(.MAX_SYM(4)) u_v2 (.h(base1), .sym_n(cnt_syms(n1_eff, 1'b0, h3_en)),
                       .d(pack_syms(n1_eff, h_push_bits, 1'b0, '0, h3_en, h3_bits)), .h_next(spec_d));
    assign spec_da = spec_d1;
  end else if (BFANY) begin : g_h_bf
    bpu_hist_vec #(.MAX_SYM(4)) u_v1 (.h(base1), .sym_n(cnt_syms(n1_eff, 1'b0, 1'b0)),
                       .d(pack_syms(n1_eff, h_push_bits, 1'b0, '0, 1'b0, '0)), .h_next(spec_d1));
    bpu_hist_vec #(.MAX_SYM(4)) u_va (.h(base1), .sym_n(cnt_syms(n1_eff, h2_en, 1'b0)),
                       .d(pack_syms(n1_eff, h_push_bits, h2_en, h2_bits, 1'b0, '0)), .h_next(spec_da));
    bpu_hist_vec #(.MAX_SYM(4)) u_v2 (.h(base1), .sym_n(cnt_syms(n1_eff, h2_en, h3_en)),
                       .d(pack_syms(n1_eff, h_push_bits, h2_en, h2_bits, h3_en, h3_bits)), .h_next(spec_d));
  end else begin : g_h_ref
    // REFONLY: M_ARCH uses linear 128-bit arch_push_vec (zero circular barrel shifter!)
    hist_t spec_n1_ck, spec_n1_ar, spec_n1, spec_qa, spec_q2;
    hist_t spec_r1_ck, spec_ra_ck, spec_r2_ck, spec_r1_ar, spec_ra_ar, spec_r2_ar;
    hist_t base_ck, base_rck;
    always_comb base_ck  = (h_mode  == M_CK) ? hist_restore(spec_q, h_ck)  : spec_q;
    always_comb base_rck = hist_restore(spec_q, hr_ck);

    bpu_hist_vec #(.MAX_SYM(2)) u_n1_ck (.h(base_ck), .sym_n(cnt_syms(n1_eff, 1'b0, 1'b0)),
                       .d(pack_syms(n1_eff, h_push_bits, 1'b0, '0, 1'b0, '0)), .h_next(spec_n1_ck));
    always_comb spec_n1_ar = arch_to_hist(arch_push_vec(arch_sr_q, arch_fh_q, arch_ex_fh_q, arch_sc_fh_q,
                               cnt_syms(n1_eff, 1'b0, 1'b0),
                               {12'b0, pack_syms(n1_eff, h_push_bits, 1'b0, '0, 1'b0, '0)}), 4'd0);
    assign spec_n1 = (h_mode == M_ARCH) ? spec_n1_ar : spec_n1_ck;

    bpu_hist_vec #(.MAX_SYM(1)) u_qa (.h(spec_q), .sym_n(cnt_syms(2'd0, g0_h_en, 1'b0)),
                       .d(pack_syms(2'd0, 6'd0, g0_h_en, g0_h_bits, 1'b0, '0)), .h_next(spec_qa));
    bpu_hist_vec #(.MAX_SYM(2)) u_q2 (.h(spec_q), .sym_n(cnt_syms(2'd0, g0_h_en, h3_en)),
                       .d(pack_syms(2'd0, 6'd0, g0_h_en, g0_h_bits, h3_en, h3_bits)), .h_next(spec_q2));

    bpu_hist_vec #(.MAX_SYM(2)) u_r1_ck (.h(base_rck), .sym_n(cnt_syms(hr_push_n, 1'b0, 1'b0)),
                       .d(pack_syms(hr_push_n, hr_push_bits, 1'b0, '0, 1'b0, '0)), .h_next(spec_r1_ck));
    bpu_hist_vec #(.MAX_SYM(3)) u_ra_ck (.h(base_rck), .sym_n(cnt_syms(hr_push_n, h2_en, 1'b0)),
                       .d(pack_syms(hr_push_n, hr_push_bits, h2_en, h2_bits, 1'b0, '0)), .h_next(spec_ra_ck));
    bpu_hist_vec #(.MAX_SYM(4)) u_r2_ck (.h(base_rck), .sym_n(cnt_syms(hr_push_n, h2_en, h3_en)),
                       .d(pack_syms(hr_push_n, hr_push_bits, h2_en, h2_bits, h3_en, h3_bits)), .h_next(spec_r2_ck));

    always_comb begin
      spec_r1_ar = arch_to_hist(arch_push_vec(arch_sr_q, arch_fh_q, arch_ex_fh_q, arch_sc_fh_q,
                     cnt_syms(hr_push_n, 1'b0, 1'b0),
                     {12'b0, pack_syms(hr_push_n, hr_push_bits, 1'b0, '0, 1'b0, '0)}), 4'd0);
      spec_ra_ar = arch_to_hist(arch_push_vec(arch_sr_q, arch_fh_q, arch_ex_fh_q, arch_sc_fh_q,
                     cnt_syms(hr_push_n, h2_en, 1'b0),
                     {12'b0, pack_syms(hr_push_n, hr_push_bits, h2_en, h2_bits, 1'b0, '0)}),
                     h2_en ? 4'd3 : 4'd0);
      spec_r2_ar = arch_to_hist(arch_push_vec(arch_sr_q, arch_fh_q, arch_ex_fh_q, arch_sc_fh_q,
                     cnt_syms(hr_push_n, h2_en, h3_en),
                     {12'b0, pack_syms(hr_push_n, hr_push_bits, h2_en, h2_bits, h3_en, h3_bits)}),
                     (h2_en ? 4'd3 : 4'd0) + (h3_en ? 4'd3 : 4'd0));
    end

    assign spec_d1 = (hr_mode == M_CK) ? spec_r1_ck : spec_r1_ar;
    assign spec_da = refetch ? ((hr_mode == M_CK) ? spec_ra_ck : spec_ra_ar) : spec_qa;
    assign spec_d  = refetch ? ((hr_mode == M_CK) ? spec_r2_ck : spec_r2_ar) : (issue ? spec_q2 : spec_n1);
  end

  // ---- speculative RAS: queue arrays + pointers + 4-slot write overlay ----
  // Read purely from REGISTERED aras_q (zero commit -> spec_a_ras_top path!)
  function automatic logic [XLEN_BITS-1:0] arch_st(input logic [RAS_PTR_W-1:0] j);
    return aras_q.st[aras_q.ptr - aras_q.cnt[RAS_PTR_W-1:0] + RAS_PTR_W'(1) + j];
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [XLEN_BITS-1:0] rd_st(input rov_t o, input logic [RASQ_W-1:0] i);
    logic [XLEN_BITS-1:0] v;
    v = st_q[i];
    if (o.arch && !i[RASQ_W-1]) v = arch_st(i[RAS_PTR_W-1:0]);
    for (int k = 0; k < 4; k++) if (o.w[k] && o.idx[k] == i) v = o.val[k];
    return v;
  endfunction

  function automatic logic [RASQ_W-1:0] rd_nos(input rov_t o, input logic [RASQ_W-1:0] i);
    logic [RASQ_W-1:0] v;
    v = nos_q[i];
    if (o.arch && !i[RASQ_W-1]) v = (i == '0) ? '0 : i - RASQ_W'(1);
    for (int k = 0; k < 4; k++) if (o.w[k] && o.idx[k] == i) v = o.nos[k];
    return v;
  endfunction

  function automatic rst_t start(input logic [1:0] mode, input ras_ck_t ck);
    rst_t s;
    s = '0;
    s.p = rp_q;
    if (mode == M_CK) begin
      s.p.tosr = ck.tosr; s.p.tosw = ck.tosw; s.p.cnt = ck.cnt;
    end else if (mode == M_ARCH) begin
      s.p.cnt  = aras_q.cnt;
      s.p.tosr = (aras_q.cnt == '0) ? '0 : RASQ_W'(aras_q.cnt - RAS_CNT_W'(1));
      s.p.tosw = RASQ_W'(aras_q.cnt);
      s.o.arch = 1'b1;
    end
    return s;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic rst_t do_op(input rst_t s0, input logic [1:0] op, input logic [XLEN_BITS-1:0] v,
                                 input logic [1:0] slot);
    rst_t s;
    s = s0;
    if (op == 2'd1) begin
      s.o.w[slot]   = 1'b1;
      s.o.idx[slot] = s0.p.tosw;
      s.o.val[slot] = v;
      s.o.nos[slot] = s0.p.tosr;
      s.p.tosr      = s0.p.tosw;
      s.p.tosw      = s0.p.tosw + RASQ_W'(1);
      if (s0.p.cnt < RAS_CNT_W'(RAS_DEPTH)) s.p.cnt = s0.p.cnt + RAS_CNT_W'(1);
    end else if (op == 2'd2 && s0.p.cnt != '0) begin
      s.p.tosr = rd_nos(s0.o, s0.p.tosr);
      s.p.cnt  = s0.p.cnt - RAS_CNT_W'(1);
    end
    return s;
  endfunction

  // Ref: comb: spec RAS update (split by stage to avoid false Verilator UNOPTFLAT)
  rst_t s_old, s_d1, s_da, s_d;
  always_comb s_old = do_op(do_op(start(r_mode, r_ck), r_op, r_val, 2'd0), r_op2, r_val2, 2'd1);
  if (REFONLY) begin : g_r_ref
    rst_t s_ra, s_r2, s_qa, s_q2;
    always_comb s_d1 = do_op(do_op(start(rr_mode, rr_ck), rr_op, rr_val, 2'd0), rr_op2, rr_val2, 2'd1);
    always_comb s_ra = do_op(s_d1, r2_op, r2_val, 2'd2);
    always_comb s_r2 = do_op(s_ra, r3_op, r3_val, 2'd3);
    always_comb s_qa = do_op(start(2'd0, '0), g0_r_op, g0_r_val, 2'd2);
    always_comb s_q2 = do_op(s_qa, r3_op, r3_val, 2'd3);
    always_comb s_da = refetch ? s_ra : s_qa;
    always_comb s_d  = refetch ? s_r2 : (issue ? s_q2 : s_old);
  end else begin : g_r_std
    always_comb s_d1 = s_old;
    always_comb s_da = BFANY ? do_op(s_d1, r2_op, r2_val, 2'd2) : s_d1;
    always_comb s_d  = do_op(s_da, r3_op, r3_val, 2'd3);
  end

  // ---- Speculative IMLI update (parallel with history/RAS) ----
  always_comb begin
    logic [7:0] ib1, i_old, i_n1, i_qa, i_q2, i_r1, i_ra, i_r2;
    case (h_mode)
      M_CK:    ib1 = i_ck;
      M_ARCH:  ib1 = arch_imli_q;
      default: ib1 = spec_imli_q;
    endcase
    i_old = imli_apply(ib1, (h_mode != 2'd0) ? i1_op : 2'd0);
    if (REFONLY) begin
      i_n1 = (h_mode == M_ARCH) ? arch_imli_q : imli_apply((h_mode == M_CK) ? i_ck : spec_imli_q, i1_op);
      i_qa = imli_apply(spec_imli_q, g0_i_op);
      i_q2 = imli_apply(i_qa, i3_op);
      i_r1 = (hr_mode == M_CK) ? imli_apply(ir_ck, ir1_op) : arch_imli_q;
      i_ra = imli_apply(i_r1, i2_op);
      i_r2 = imli_apply(i_ra, i3_op);
      spec_imli_d1 = i_r1;
      spec_imli_da = refetch ? i_ra : i_qa;
      spec_imli_d  = refetch ? i_r2 : (issue ? i_q2 : i_n1);
    end else begin
      spec_imli_d1 = i_old;
      spec_imli_da = BFANY ? imli_apply(spec_imli_d1, i2_op) : spec_imli_d1;
      spec_imli_d  = imli_apply(spec_imli_da, i3_op);
    end
  end

  always_comb begin
    spec_ck.h.head      = spec_q.head;
    spec_ck.h.fh        = spec_q.fh;
    spec_ck.h.ex_fh     = spec_q.ex_fh;
    spec_ck.h.sc_fh     = spec_q.sc_fh;
    spec_ck.r           = '{tosr: rp_q.tosr, tosw: rp_q.tosw, cnt: rp_q.cnt, top: st_q[rp_q.tosr]};
    spec_ck.imli        = spec_imli_q;
    spec_ras_nonempty   = (rp_q.cnt != '0);
    spec_ras_top        = st_q[rp_q.tosr];
    spec_fh             = spec_q.fh;
  end

  always_comb begin
    spec1_ck.h.head     = spec_d1.head;
    spec1_ck.h.fh       = spec_d1.fh;
    spec1_ck.h.ex_fh    = spec_d1.ex_fh;
    spec1_ck.h.sc_fh    = spec_d1.sc_fh;
    spec1_ck.r          = '{tosr: s_d1.p.tosr, tosw: s_d1.p.tosw, cnt: s_d1.p.cnt, top: rd_st(s_d1.o, s_d1.p.tosr)};
    spec1_ck.imli       = spec_imli_d1;
    spec1_ras_nonempty  = (s_d1.p.cnt != '0);
    spec1_ras_top       = rd_st(s_d1.o, s_d1.p.tosr);
    spec1_fh            = spec_d1.fh;
  end

  always_comb begin
    spec_a_ck.h.head    = spec_da.head;
    spec_a_ck.h.fh      = spec_da.fh;
    spec_a_ck.h.ex_fh   = spec_da.ex_fh;
    spec_a_ck.h.sc_fh   = spec_da.sc_fh;
    spec_a_ck.r         = '{tosr: s_da.p.tosr, tosw: s_da.p.tosw, cnt: s_da.p.cnt, top: rd_st(s_da.o, s_da.p.tosr)};
    spec_a_ck.imli      = spec_imli_da;
    spec_a_ras_nonempty = (s_da.p.cnt != '0);
    spec_a_ras_top      = rd_st(s_da.o, s_da.p.tosr);
    spec_a_fh           = spec_da.fh;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_q       <= '0;
      arch_sr_q    <= '0;
      arch_fh_q    <= '0;
      arch_ex_fh_q <= '0;
      arch_sc_fh_q <= '0;
      arch_imli_q  <= 8'd0;
      spec_imli_q  <= 8'd0;
      rp_q         <= '0;
      aras_q       <= '0;
      for (int j = 0; j < RASQ_N; j++) begin st_q[j] <= '0; nos_q[j] <= '0; end
    end else begin
      spec_q       <= spec_d;
      arch_sr_q    <= arch_sr_d;
      arch_fh_q    <= arch_fh_d;
      arch_ex_fh_q <= arch_ex_fh_d;
      arch_sc_fh_q <= arch_sc_fh_d;
      arch_imli_q  <= arch_imli_d;
      spec_imli_q  <= spec_imli_d;
      rp_q         <= s_d.p;
      aras_q       <= aras_d;
      for (int j = 0; j < RASQ_N; j++) begin
        st_q[j]  <= rd_st(s_d.o, RASQ_W'(j));
        nos_q[j] <= rd_nos(s_d.o, RASQ_W'(j));
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{h2_en, h2_bits, r2_op, r2_val, refetch, issue, g0_h_en, g0_h_bits, g0_r_op, g0_r_val,
                       hr_mode, hr_ck, hr_push_n, hr_push_bits, rr_mode, rr_ck, rr_op, rr_val, rr_op2, rr_val2,
                       i1_op, i_ck, i2_op, i3_op, ir1_op, ir_ck, g0_i_op};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
