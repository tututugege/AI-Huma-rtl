// Ref: front-end/BPU/BPU_pipe.h  State::spec / arch / sras / aras (Clean BPU v11: 256b ring, 200b arch_sr, unified ex_fh[3][6])
`default_nettype none

module bpu_spec import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // commit stream (architectural copies)
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0] base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  upd_is_rvc,
  input  logic [XLEN_BITS-1:0] target   [NCOMMIT],
  // !refetch && !issue restore command (ONLY registered ovr_pend_q: 0..1 symbol, 0..1 RAS op)
  input  logic [1:0]          h_mode,
  input  hist_ck_t            h_ck,
  input  logic                h_push_en,
  input  logic [HSYM_W-1:0]   h_push_bits,
  input  logic [1:0]          r_mode,
  input  ras_ck_t             r_ck,
  input  logic [1:0]          r_op,
  input  logic [XLEN_BITS-1:0] r_val,
  // Registered S0 view (always from registered spec_q / rp_q / st_q!)
  output ck_t                 spec_ck,
  output logic                spec_ras_nonempty,
  output logic [XLEN_BITS-1:0] spec_ras_top,
  output ex_fh_t              spec_ex_fh,
  // Control + S0 single-block issue push + refetch-only restore command
  input  logic                refetch,
  input  logic                ovr,
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
  input  logic [XLEN_BITS-1:0] rr_val,
  input  logic [1:0]          rr_op2,
  input  logic [XLEN_BITS-1:0] rr_val2
);

  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  // Architectural history never rolls back: 200-bit linear shift register (covers EX_GHR_LEN[5] = 178)
  localparam int ARCH_SR_W = 200;

  hist_t                spec_q, spec_d;
  logic [ARCH_SR_W-1:0] arch_sr_q, arch_sr_d;
  ex_fh_t               arch_ex_fh_q, arch_ex_fh_d;
  rasc_t                aras_q, aras_d;
  logic [XLEN_BITS-1:0] st_q  [RASQ_N];
  logic [RASQ_W-1:0]    nos_q [RASQ_N];
  rptr_t                rp_q;

  // ---- Commit stream -> architectural history (0..8 symbols) ----
  logic [23:0] arch_d_bits;
  logic [3:0]  arch_sym_n;

  always_comb begin
    logic [2:0] hs_t;
    arch_d_bits = '0;
    arch_sym_n  = '0;
    hs_t        = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      hs_t = hsym_of(base_pc[i], target[i]);
      if (upd_valid[i] && (br_type[i] != BR_NONCTL) && actual_dir[i]) begin
        arch_d_bits = {arch_d_bits[20:0], hs_t[0], hs_t[1], hs_t[2]};
        arch_sym_n  = arch_sym_n + 4'd1;
      end
    end
  end

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
      default: return x;
    endcase
  endfunction

  typedef struct packed {
    logic [ARCH_SR_W-1:0] sr;
    ex_fh_t               ex_fh;
  } arch_hist_t;

  function automatic arch_hist_t arch_push_vec(input logic [ARCH_SR_W-1:0] sr,
                                               input ex_fh_t ex_fh,
                                               input logic [3:0] sn, input logic [23:0] d);
    arch_hist_t res;
    logic [5:0]  nb;
    logic [23:0] keep, din, din_of;
    logic [23:0] ex_outw [EX_TN];
    nb = {2'b0, sn} + {1'b0, sn, 1'b0}; // 3 * sn (0..24)
    for (int u = 0; u < 24; u++) begin
      keep[u] = (6'(u) < nb);
      din[u]  = d[u] && keep[u];
    end
    din_of = '0;
    for (int c = 1; c <= 8; c++) begin
      if (sn == 4'(c)) begin
        for (int j = 0; j < 3 * c; j++) din_of[j] = d[3 * c - 1 - j];
      end
    end
    res.sr = (sr << nb) | {{(ARCH_SR_W - 24){1'b0}}, din};
    for (int i = 0; i < EX_TN; i++) begin
      logic [23:0] raw_o;
      raw_o = '0;
      for (int j = 0; j < 24; j++) begin
        if (j < ex_ghr_len(i)) raw_o[j] = sr[ex_ghr_len(i) - 1 - j];
        else                   raw_o[j] = din_of[j - ex_ghr_len(i)];
      end
      ex_outw[i] = '0;
      for (int c = 1; c <= 8; c++) begin
        if (sn == 4'(c)) begin
          for (int u = 0; u < 3 * c; u++) ex_outw[i][u] = raw_o[3 * c - 1 - u];
        end
      end
    end
    for (int k = 0; k < EX_FH_K; k++) begin
      for (int i = 0; i < EX_TN; i++) begin
        logic [EX_FH_W-1:0] acc;
        acc = arch_rotl_sym_ex(ex_fh[k][i], sn, ex_fh_len(k));
        for (int u = 0; u < 24; u++) begin
          acc = acc ^ arch_rotl_const_ex(EX_FH_W'(din[u]) ^ (EX_FH_W'(ex_outw[i][u]) << (ex_ghr_len(i) % ex_fh_len(k))),
                                         u % ex_fh_len(k), ex_fh_len(k));
        end
        res.ex_fh[k][i] = acc;
      end
    end
    return res;
  endfunction

  function automatic hist_t arch_to_hist(input arch_hist_t a);
    hist_t h;
    h       = '0;
    h.head  = '0;
    h.ex_fh = a.ex_fh;
    for (int k = 0; k < ARCH_SR_W; k++) begin
      h.ring[HR_PTR_W'(0) - HR_PTR_W'(1) - HR_PTR_W'(k)] = a.sr[k];
    end
    return h;
  endfunction

  arch_hist_t arch_next_st;
  always_comb begin
    arch_next_st = arch_push_vec(arch_sr_q, arch_ex_fh_q, arch_sym_n, arch_d_bits);
    arch_sr_d    = arch_next_st.sr;
    arch_ex_fh_d = arch_next_st.ex_fh;
  end

  // ---- Parallel 3-level Kogge-Stone architectural RAS update (8 commit lanes) ----
  typedef struct packed {
    logic signed [4:0]    d;
    logic [RAS_CNT_W-1:0] lo;
    logic [RAS_CNT_W-1:0] hi;
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

  // ---- Speculative history update (2A+2B: pure registered spec_q / arch_sr_q!) ----
  function automatic logic [23:0] pack_syms(input logic [1:0] n1, input logic [5:0] b1,
                                            input logic en2, input logic [2:0] b2);
    logic [23:0] d;
    d = '0;
    if (n1 >= 2'd1) d = {d[20:0], b1[0], b1[1], b1[2]};
    if (n1 >= 2'd2) d = {d[20:0], b1[3], b1[4], b1[5]};
    if (en2)        d = {d[20:0], b2[0], b2[1], b2[2]};
    return d;
  endfunction

  logic n1_en;
  assign n1_en = (h_mode != 2'd0) && h_push_en;

  hist_t spec_n1, spec_q1, spec_r1_ck, spec_r1_ar;
  hist_t base_ck, base_rck;
  always_comb base_ck  = (h_mode == M_CK) ? hist_restore(spec_q, h_ck) : spec_q;
  always_comb base_rck = hist_restore(spec_q, hr_ck);

  bpu_hist_vec #(.MAX_SYM(1)) u_n1_ck (.h(base_ck), .sym_n({3'd0, n1_en}),
                     .d(pack_syms(2'd0, 6'd0, n1_en, h_push_bits)), .h_next(spec_n1));

  bpu_hist_vec #(.MAX_SYM(1)) u_q1 (.h(spec_q), .sym_n({3'd0, g0_h_en}),
                     .d(pack_syms(2'd0, 6'd0, g0_h_en, g0_h_bits)), .h_next(spec_q1));

  bpu_hist_vec #(.MAX_SYM(2)) u_r1_ck (.h(base_rck), .sym_n({2'd0, hr_push_n}),
                     .d(pack_syms(hr_push_n, hr_push_bits, 1'b0, '0)), .h_next(spec_r1_ck));

  always_comb begin
    arch_hist_t a_reg;
    a_reg.sr    = arch_sr_q;
    a_reg.ex_fh = arch_ex_fh_q;
    spec_r1_ar  = arch_to_hist(a_reg);
  end

  assign spec_d = refetch ? ((hr_mode == M_CK) ? spec_r1_ck : spec_r1_ar)
                          : (ovr ? spec_q : (issue ? spec_q1 : spec_n1));

  // ---- Speculative RAS: 64-entry queue + 3-slot write overlay ----
  function automatic logic [XLEN_BITS-1:0] arch_st(input logic [RAS_PTR_W-1:0] j);
    return aras_q.st[aras_q.ptr - aras_q.cnt[RAS_PTR_W-1:0] + RAS_PTR_W'(1) + j];
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [XLEN_BITS-1:0] rd_st(input rov_t o, input logic [RASQ_W-1:0] i);
    logic [XLEN_BITS-1:0] v;
    v = st_q[i];
    if (o.arch && !i[RASQ_W-1]) v = arch_st(i[RAS_PTR_W-1:0]);
    for (int k = 0; k < 3; k++) if (o.w[k] && o.idx[k] == i) v = o.val[k];
    return v;
  endfunction

  function automatic logic [RASQ_W-1:0] rd_nos(input rov_t o, input logic [RASQ_W-1:0] i);
    logic [RASQ_W-1:0] v;
    v = nos_q[i];
    if (o.arch && !i[RASQ_W-1]) v = (i == '0) ? '0 : i - RASQ_W'(1);
    for (int k = 0; k < 3; k++) if (o.w[k] && o.idx[k] == i) v = o.nos[k];
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

  rst_t s_old, s_d1, s_q1, s_d;
  always_comb begin
    rst_t s_n1;
    s_n1  = '0;
    s_n1.p = (r_mode == M_CK) ? '{tosr: r_ck.tosr, tosw: r_ck.tosw, cnt: r_ck.cnt} : rp_q;
    s_old = do_op(s_n1, r_op, r_val, 2'd0);
  end
  always_comb s_d1 = do_op(do_op(start(rr_mode, rr_ck), rr_op, rr_val, 2'd0), rr_op2, rr_val2, 2'd1);
  always_comb s_q1 = do_op(start(2'd0, '0), g0_r_op, g0_r_val, 2'd2);
  always_comb s_d  = refetch ? s_d1 : (ovr ? '{p: rp_q, o: '0} : (issue ? s_q1 : s_old));

  always_comb begin
    spec_ck.h.head    = spec_q.head;
    spec_ck.h.ex_fh   = spec_q.ex_fh;
    spec_ck.r         = '{tosr: rp_q.tosr, tosw: rp_q.tosw, cnt: rp_q.cnt, top: st_q[rp_q.tosr]};
    spec_ras_nonempty = (rp_q.cnt != '0);
    spec_ras_top      = st_q[rp_q.tosr];
    spec_ex_fh        = spec_q.ex_fh;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_q       <= '0;
      arch_sr_q    <= '0;
      arch_ex_fh_q <= '0;
      rp_q         <= '0;
      aras_q       <= '0;
      for (int j = 0; j < RASQ_N; j++) begin st_q[j] <= '0; nos_q[j] <= '0; end
    end else begin
      spec_q       <= spec_d;
      arch_sr_q    <= arch_sr_d;
      arch_ex_fh_q <= arch_ex_fh_d;
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
  assign unused_ok = ^{r_ck.top, rr_ck.top};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
