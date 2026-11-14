// Ref: front-end/BPU/BPU_pipe.h  State::spec / arch / sras / aras (speculative and architectural history and RAS)
`default_nettype none

// Speculative and architectural global history (256-bit ring + head + 12 folded histories) and return-address stack.
// The commit stream advances the architectural copies, one taken-branch symbol or call / return per commit lane.
// The speculative copies are updated by exactly one command per cycle (the front end's decision of the cycle):
//   history mode  HOLD: keep   PUSH: push on the current state   CK: load a checkpoint (head + folds), then push
//                 ARCH: load the architectural copy (after this cycle's commits)
//   RAS mode      same four, with ARCH = the queue rebuilt from the architectural stack, CK = (tosr, tosw, cnt) restore
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
  // speculative update command
  input  logic [1:0]          h_mode,
  input  hist_ck_t            h_ck,
  input  logic                h_push_en,
  input  logic [HSYM_W-1:0]   h_push_bits,
  input  logic [1:0]          r_mode,
  input  ras_ck_t             r_ck,
  input  logic [1:0]          r_op,
  input  logic [XLEN_BITS-1:0]         r_val,
  // second step on the state the command leaves: the S0 push of FE_RFAST bit0 / FE_BFAST (en = 0 / op = 0 otherwise)
  input  logic                h2_en,
  input  logic [HSYM_W-1:0]   h2_bits,
  input  logic [1:0]          r2_op,
  input  logic [XLEN_BITS-1:0]         r2_val,
  // state before this cycle's update
  output ck_t                 spec_ck,
  output logic                spec_ras_nonempty,
  output logic [XLEN_BITS-1:0]         spec_ras_top,
  output fh_t                 spec_fh,
  // state after the command, before the second step (the state S0 looks up with in the FAST configuration)
  output ck_t                 spec1_ck,
  output logic                spec1_ras_nonempty,
  output logic [XLEN_BITS-1:0]         spec1_ras_top,
  output fh_t                 spec1_fh,
  // REFONLY: refetch flag and the refetch-only command (see bpu_cmd); spec1_* then is the state after that command
  input  logic                refetch,
  input  logic [1:0]          hr_mode,
  input  hist_ck_t            hr_ck,
  input  logic                hr_push_en,
  input  logic [HSYM_W-1:0]   hr_push_bits,
  input  logic [1:0]          rr_mode,
  input  ras_ck_t             rr_ck,
  input  logic [1:0]          rr_op,
  input  logic [XLEN_BITS-1:0]         rr_val
);

  localparam bit FAST    = (FE_RFAST & 1) != 0 || FE_BFAST != 0;
  localparam bit BFANY   = (FE_BFAST & 3) != 0;
  localparam bit REFONLY = FAST && !BFANY;

  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  /* verilator lint_off UNUSEDSIGNAL */   // only head / folded histories of spec_d1 are read (S0 view)
  hist_t spec_d1;
  /* verilator lint_on UNUSEDSIGNAL */
  hist_t spec_q, spec_d, arch_q, arch_d;
  rasc_t aras_q, aras_d;
  logic [XLEN_BITS-1:0] st_q  [RASQ_N];   // speculative RAS queue
  logic [RASQ_W-1:0]    nos_q [RASQ_N];
  rptr_t                rp_q;

  // Ref: push_arch: every taken control instruction of the commit lanes pushes its symbol (newest bit first in d)
  logic [23:0] arch_d_bits;
  logic [4:0]  arch_n;

  always_comb begin
    arch_d_bits = '0;
    arch_n      = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      if (upd_valid[i] && (br_type[i] != BR_NONCTL) && actual_dir[i]) begin
        arch_d_bits = {arch_d_bits[20:0], hsym_of(base_pc[i], target[i])[0], hsym_of(base_pc[i], target[i])[1],
                       hsym_of(base_pc[i], target[i])[2]};
        arch_n      = arch_n + 5'd3;
      end
    end
  end

  bpu_hist_vec u_arch_push (.h(arch_q), .n(arch_n), .d(arch_d_bits), .h_next(arch_d));

  // Ref: commit loop: calls / returns move the architectural RAS
  always_comb begin
    aras_d = aras_q;
    for (int i = 0; i < NCOMMIT; i++) begin
      if (upd_valid[i]) begin
        if (br_type[i] == BR_CALL || br_type[i] == BR_ICALL)
          aras_d = ras_push(aras_d, base_pc[i] + (upd_is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4)));
        else if (br_type[i] == BR_RET)                       aras_d = ras_pop(aras_d);
      end
    end
  end

  // history bits of up to two pushes as the (newest first) word of bpu_hist_vec; a push is 3 bits, bit 0 first
  function automatic logic [23:0] dbits(input logic en1, input logic [HSYM_W-1:0] b1, input logic en2,
                                        input logic [HSYM_W-1:0] b2);
    logic [23:0] d;
    d = '0;
    if (en2) begin
      d[2:0] = {b2[0], b2[1], b2[2]};
      if (en1) d[5:3] = {b1[0], b1[1], b1[2]};
    end else if (en1) begin
      d[2:0] = {b1[0], b1[1], b1[2]};
    end
    return d;
  endfunction

  // Ref: comb: spec history update (command; the base state of the command is spec_q / checkpoint / architectural copy)
  hist_t base1;
  logic  en1;
  always_comb begin
    base1 = spec_q;
    case (h_mode)
      M_CK:    base1 = hist_restore(spec_q, h_ck);
      M_ARCH:  base1 = arch_d;
      default: base1 = spec_q;
    endcase
    en1 = (h_mode != 2'd0) && h_push_en;
  end

  if (!FAST) begin : g_h_old
    always_comb begin
      spec_d1 = hist_push_sym(base1, en1, h_push_bits);
      spec_d  = spec_d1;
    end
  end else if (BFANY) begin : g_h_bf
    // one linear multi-bit push per result instead of chained single-bit pushes (command push, then S0 push)
    bpu_hist_vec u_v1 (.h(base1), .n(en1 ? 5'd3 : 5'd0), .d(dbits(en1, h_push_bits, 1'b0, '0)), .h_next(spec_d1));
    bpu_hist_vec u_v2 (.h(base1), .n(5'(3 * (int'(en1) + int'(h2_en)))), .d(dbits(en1, h_push_bits, h2_en, h2_bits)),
                       .h_next(spec_d));
  end else begin : g_h_ref
    hist_t spec_old, spec_r1, spec_r2, base_r;
    always_comb begin
      spec_old = hist_push_sym(base1, en1, h_push_bits);
      base_r   = (hr_mode == M_CK) ? hist_restore(spec_q, hr_ck) : arch_d;
      spec_d1  = spec_r1;
    end
    bpu_hist_vec u_r1 (.h(base_r), .n(hr_push_en ? 5'd3 : 5'd0), .d(dbits(hr_push_en, hr_push_bits, 1'b0, '0)),
                       .h_next(spec_r1));
    bpu_hist_vec u_r2 (.h(base_r), .n(5'(3 * (int'(hr_push_en) + int'(h2_en)))),
                       .d(dbits(hr_push_en, hr_push_bits, h2_en, h2_bits)), .h_next(spec_r2));
    always_comb spec_d = refetch ? spec_r2 : spec_old;
  end

  // ---- speculative RAS: queue arrays + pointers; a command = (pointers, overlay of the array writes) ----
  function automatic logic [XLEN_BITS-1:0] arch_st(input logic [RAS_PTR_W-1:0] j);
    return aras_d.st[aras_d.ptr - aras_d.cnt[RAS_PTR_W-1:0] + RAS_PTR_W'(1) + j];
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */   // the overlay / checkpoint fields a function does not read
  function automatic logic [XLEN_BITS-1:0] rd_st(input rov_t o, input logic [RASQ_W-1:0] i);
    logic [XLEN_BITS-1:0] v;
    v = st_q[i];
    if (o.arch && !i[RASQ_W-1]) v = arch_st(i[RAS_PTR_W-1:0]);
    if (o.w1 && o.i1 == i) v = o.v1;
    if (o.w2 && o.i2 == i) v = o.v2;
    return v;
  endfunction

  function automatic logic [RASQ_W-1:0] rd_nos(input rov_t o, input logic [RASQ_W-1:0] i);
    logic [RASQ_W-1:0] v;
    v = nos_q[i];
    if (o.arch && !i[RASQ_W-1]) v = (i == '0) ? '0 : i - RASQ_W'(1);
    if (o.w1 && o.i1 == i) v = o.n1;
    if (o.w2 && o.i2 == i) v = o.n2;
    return v;
  endfunction

  // the state a command starts from: HOLD / PUSH = the current queue, CK = the checkpoint pointers (the queue keeps
  // what they reach), ARCH = the queue rebuilt from the committed stack (bottom first at slot 0)
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
                                 input logic second);
    rst_t s;
    s = s0;
    if (op == 2'd1) begin
      if (second) begin s.o.w2 = 1'b1; s.o.i2 = s0.p.tosw; s.o.v2 = v; s.o.n2 = s0.p.tosr; end
      else        begin s.o.w1 = 1'b1; s.o.i1 = s0.p.tosw; s.o.v1 = v; s.o.n1 = s0.p.tosr; end
      s.p.tosr = s0.p.tosw;
      s.p.tosw = s0.p.tosw + RASQ_W'(1);
      if (s0.p.cnt < RAS_CNT_W'(RAS_DEPTH)) s.p.cnt = s0.p.cnt + RAS_CNT_W'(1);
    end else if (op == 2'd2 && s0.p.cnt != '0) begin
      s.p.tosr = rd_nos(s0.o, s0.p.tosr);
      s.p.cnt  = s0.p.cnt - RAS_CNT_W'(1);
    end
    return s;
  endfunction

  // Ref: comb: spec RAS update
  rst_t s_old, s_d1, s_d;
  always_comb s_old = do_op(start(r_mode, r_ck), r_op, r_val, 1'b0);
  if (REFONLY) begin : g_r_ref
    always_comb s_d1 = do_op(start(rr_mode, rr_ck), rr_op, rr_val, 1'b0);
    always_comb s_d  = refetch ? do_op(s_d1, r2_op, r2_val, 1'b1) : s_old;
  end else begin : g_r_std
    always_comb s_d1 = s_old;
    always_comb s_d  = do_op(s_d1, r2_op, r2_val, 1'b1);
  end

  always_comb begin
    spec_ck.h.head    = spec_q.head;
    spec_ck.h.fh      = spec_q.fh;
    spec_ck.r         = '{tosr: rp_q.tosr, tosw: rp_q.tosw, cnt: rp_q.cnt, top: st_q[rp_q.tosr]};
    spec_ras_nonempty = (rp_q.cnt != '0);
    spec_ras_top      = st_q[rp_q.tosr];
    spec_fh           = spec_q.fh;
    spec1_ck.h.head    = spec_d1.head;
    spec1_ck.h.fh      = spec_d1.fh;
    spec1_ck.r         = '{tosr: s_d1.p.tosr, tosw: s_d1.p.tosw, cnt: s_d1.p.cnt, top: rd_st(s_d1.o, s_d1.p.tosr)};
    spec1_ras_nonempty = (s_d1.p.cnt != '0);
    spec1_ras_top      = rd_st(s_d1.o, s_d1.p.tosr);
    spec1_fh           = spec_d1.fh;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_q <= '0;
      arch_q <= '0;
      rp_q     <= '0;
      aras_q <= '0;
      for (int j = 0; j < RASQ_N; j++) begin st_q[j] <= '0; nos_q[j] <= '0; end
    end else begin
      spec_q <= spec_d;
      arch_q <= arch_d;
      rp_q     <= s_d.p;
      aras_q <= aras_d;
      for (int j = 0; j < RASQ_N; j++) begin
        st_q[j]  <= rd_st(s_d.o, RASQ_W'(j));
        nos_q[j] <= rd_nos(s_d.o, RASQ_W'(j));
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;   // refetch-only command: used only in REFONLY
  assign unused_ok = ^{h2_en, h2_bits, refetch, hr_mode, hr_ck, hr_push_en, hr_push_bits, rr_mode, rr_ck, rr_op,
                       rr_val};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
