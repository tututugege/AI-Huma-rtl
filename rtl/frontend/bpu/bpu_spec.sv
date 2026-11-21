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
  input  logic [XLEN_BITS-1:0]         rr_val2
);

  localparam bit FAST    = (FE_RFAST & 1) != 0 || FE_BFAST != 0;
  localparam bit BFANY   = (FE_BFAST & 3) != 0;
  localparam bit REFONLY = FAST && !BFANY;

  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  /* verilator lint_off UNUSEDSIGNAL */
  hist_t spec_d1, spec_da;
  /* verilator lint_on UNUSEDSIGNAL */
  hist_t spec_q, spec_d, arch_q, arch_d;
  rasc_t aras_q, aras_d;
  logic [XLEN_BITS-1:0] st_q  [RASQ_N];
  logic [RASQ_W-1:0]    nos_q [RASQ_N];
  rptr_t                rp_q;

  // Ref: push_arch: every taken control instruction of the commit lanes pushes its symbol
  logic [23:0] arch_d_bits;
  logic [3:0]  arch_sym_n;

  always_comb begin
    arch_d_bits = '0;
    arch_sym_n  = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      if (upd_valid[i] && (br_type[i] != BR_NONCTL) && actual_dir[i]) begin
        arch_d_bits = {arch_d_bits[20:0], hsym_of(base_pc[i], target[i])[0], hsym_of(base_pc[i], target[i])[1],
                       hsym_of(base_pc[i], target[i])[2]};
        arch_sym_n  = arch_sym_n + 4'd1;
      end
    end
  end

  bpu_hist_vec #(.MAX_SYM(8)) u_arch_push (.h(arch_q), .sym_n(arch_sym_n), .d(arch_d_bits), .h_next(arch_d));

  // Ref: commit loop: calls / returns move the architectural RAS
  always_comb begin
    aras_d = aras_q;
    for (int i = 0; i < NCOMMIT; i++) begin
      if (upd_valid[i]) begin
        if (br_type[i] == BR_CALL || br_type[i] == BR_ICALL)
          aras_d = ras_push(aras_d, base_pc[i] + (upd_is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4)));
        else if (br_type[i] == BR_RET)
          aras_d = ras_pop(aras_d);
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

  // Ref: comb: spec history update
  hist_t base1;
  logic [1:0] n1_eff;
  always_comb begin
    base1 = spec_q;
    case (h_mode)
      M_CK:    base1 = hist_restore(spec_q, h_ck);
      M_ARCH:  base1 = arch_d;
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
    // REFONLY: S0 Block A/B on !refetch starts directly from spec_q (independent of S2 ovr / r1_q!)
    hist_t spec_n1, spec_qa, spec_q2, spec_r1, spec_ra, spec_r2, base_r;
    always_comb base_r = (hr_mode == M_CK) ? hist_restore(spec_q, hr_ck) : arch_d;
    bpu_hist_vec #(.MAX_SYM(2)) u_n1 (.h(base1), .sym_n(cnt_syms(n1_eff, 1'b0, 1'b0)),
                       .d(pack_syms(n1_eff, h_push_bits, 1'b0, '0, 1'b0, '0)), .h_next(spec_n1));
    bpu_hist_vec #(.MAX_SYM(1)) u_qa (.h(spec_q), .sym_n(cnt_syms(2'd0, g0_h_en, 1'b0)),
                       .d(pack_syms(2'd0, 6'd0, g0_h_en, g0_h_bits, 1'b0, '0)), .h_next(spec_qa));
    bpu_hist_vec #(.MAX_SYM(2)) u_q2 (.h(spec_q), .sym_n(cnt_syms(2'd0, g0_h_en, h3_en)),
                       .d(pack_syms(2'd0, 6'd0, g0_h_en, g0_h_bits, h3_en, h3_bits)), .h_next(spec_q2));
    bpu_hist_vec #(.MAX_SYM(2)) u_r1 (.h(base_r), .sym_n(cnt_syms(hr_push_n, 1'b0, 1'b0)),
                       .d(pack_syms(hr_push_n, hr_push_bits, 1'b0, '0, 1'b0, '0)), .h_next(spec_r1));
    bpu_hist_vec #(.MAX_SYM(3)) u_ra (.h(base_r), .sym_n(cnt_syms(hr_push_n, h2_en, 1'b0)),
                       .d(pack_syms(hr_push_n, hr_push_bits, h2_en, h2_bits, 1'b0, '0)), .h_next(spec_ra));
    bpu_hist_vec #(.MAX_SYM(4)) u_r2 (.h(base_r), .sym_n(cnt_syms(hr_push_n, h2_en, h3_en)),
                       .d(pack_syms(hr_push_n, hr_push_bits, h2_en, h2_bits, h3_en, h3_bits)), .h_next(spec_r2));
    assign spec_d1 = spec_r1;
    assign spec_da = refetch ? spec_ra : spec_qa;
    assign spec_d  = refetch ? spec_r2 : (issue ? spec_q2 : spec_n1);
  end

  // ---- speculative RAS: queue arrays + pointers + 4-slot write overlay ----
  function automatic logic [XLEN_BITS-1:0] arch_st(input logic [RAS_PTR_W-1:0] j);
    return aras_d.st[aras_d.ptr - aras_d.cnt[RAS_PTR_W-1:0] + RAS_PTR_W'(1) + j];
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
      s.p.cnt  = aras_d.cnt;
      s.p.tosr = (aras_d.cnt == '0) ? '0 : RASQ_W'(aras_d.cnt - RAS_CNT_W'(1));
      s.p.tosw = RASQ_W'(aras_d.cnt);
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

  always_comb begin
    spec_ck.h.head      = spec_q.head;
    spec_ck.h.fh        = spec_q.fh;
    spec_ck.r           = '{tosr: rp_q.tosr, tosw: rp_q.tosw, cnt: rp_q.cnt, top: st_q[rp_q.tosr]};
    spec_ras_nonempty   = (rp_q.cnt != '0);
    spec_ras_top        = st_q[rp_q.tosr];
    spec_fh             = spec_q.fh;
  end

  always_comb begin
    spec1_ck.h.head     = spec_d1.head;
    spec1_ck.h.fh       = spec_d1.fh;
    spec1_ck.r          = '{tosr: s_d1.p.tosr, tosw: s_d1.p.tosw, cnt: s_d1.p.cnt, top: rd_st(s_d1.o, s_d1.p.tosr)};
    spec1_ras_nonempty  = (s_d1.p.cnt != '0);
    spec1_ras_top       = rd_st(s_d1.o, s_d1.p.tosr);
    spec1_fh            = spec_d1.fh;
  end

  always_comb begin
    spec_a_ck.h.head    = spec_da.head;
    spec_a_ck.h.fh      = spec_da.fh;
    spec_a_ck.r         = '{tosr: s_da.p.tosr, tosw: s_da.p.tosw, cnt: s_da.p.cnt, top: rd_st(s_da.o, s_da.p.tosr)};
    spec_a_ras_nonempty = (s_da.p.cnt != '0);
    spec_a_ras_top      = rd_st(s_da.o, s_da.p.tosr);
    spec_a_fh           = spec_da.fh;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_q <= '0;
      arch_q <= '0;
      rp_q   <= '0;
      aras_q <= '0;
      for (int j = 0; j < RASQ_N; j++) begin st_q[j] <= '0; nos_q[j] <= '0; end
    end else begin
      spec_q <= spec_d;
      arch_q <= arch_d;
      rp_q   <= s_d.p;
      aras_q <= aras_d;
      for (int j = 0; j < RASQ_N; j++) begin
        st_q[j]  <= rd_st(s_d.o, RASQ_W'(j));
        nos_q[j] <= rd_nos(s_d.o, RASQ_W'(j));
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{h2_en, h2_bits, r2_op, r2_val, refetch, issue, g0_h_en, g0_h_bits, g0_r_op, g0_r_val,
                       hr_mode, hr_ck, hr_push_n, hr_push_bits, rr_mode, rr_ck, rr_op, rr_val, rr_op2, rr_val2};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
