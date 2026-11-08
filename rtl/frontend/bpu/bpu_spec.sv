// Ref: front-end/BPU/BPU_pipe.h  State::spec / arch / sras / aras (speculative and architectural history and RAS)
`default_nettype none

// Speculative and architectural global history (256-bit ring + head + 12 folded histories) and return-address stack.
// The commit stream advances the architectural copies, one taken-branch symbol or call / return per commit lane.
// The speculative copies are updated by exactly one command per cycle (the front end's decision of the cycle):
//   history mode  HOLD: keep   PUSH: push on the current state   CK: load a checkpoint (head + folds), then push
//                 ARCH: load the architectural copy (after this cycle's commits)
//   RAS mode      same four, with ARCH = architectural stack, CK = (ptr, cnt, top) restore
module bpu_spec import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // commit stream (architectural copies)
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [31:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [31:0]         target   [NCOMMIT],
  // speculative update command
  input  logic [1:0]          h_mode,
  input  hist_ck_t            h_ck,
  input  logic                h_push_en,
  input  logic [HSYM_W-1:0]   h_push_bits,
  input  logic [1:0]          r_mode,
  input  ras_ck_t             r_ck,
  input  logic [1:0]          r_op,
  input  logic [31:0]         r_val,
  // second step on the state the command leaves: the S0 push of FE_RFAST bit0 / FE_BFAST (en = 0 / op = 0 otherwise)
  input  logic                h2_en,
  input  logic [HSYM_W-1:0]   h2_bits,
  input  logic [1:0]          r2_op,
  input  logic [31:0]         r2_val,
  // state before this cycle's update
  output ck_t                 spec_ck,
  output logic                spec_ras_nonempty,
  output logic [31:0]         spec_ras_top,
  output fh_t                 spec_fh,
  // state after the command, before the second step (the state S0 looks up with in the FAST configuration)
  output ck_t                 spec1_ck,
  output logic                spec1_ras_nonempty,
  output logic [31:0]         spec1_ras_top,
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
  input  logic [31:0]         rr_val
);

  localparam bit FAST    = (FE_RFAST & 1) != 0 || FE_BFAST != 0;
  localparam bit BFANY   = (FE_BFAST & 3) != 0;
  localparam bit REFONLY = FAST && !BFANY;

  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  hist_t spec_q, spec_d, spec_d1, arch_q, arch_d;
  ras_t  sras_q, sras_d, sras_d1, sras_old, aras_q, aras_d;

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
        if (br_type[i] == BR_CALL || br_type[i] == BR_ICALL) aras_d = ras_push(aras_d, base_pc[i] + 32'd4);
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

  // Ref: comb: spec RAS update
  ras_t rbase1;
  always_comb begin
    rbase1 = sras_q;
    case (r_mode)
      M_CK:    rbase1 = ras_restore(sras_q, r_ck);
      M_ARCH:  rbase1 = aras_d;
      default: rbase1 = sras_q;
    endcase
  end
  always_comb sras_old = (r_mode == 2'd0) ? sras_q : ras_op(rbase1, r_op, r_val);
  if (REFONLY) begin : g_r_ref
    ras_t sras_r1;
    always_comb sras_r1 = ras_op((rr_mode == M_CK) ? ras_restore(sras_q, rr_ck) : aras_d, rr_op, rr_val);
    always_comb sras_d1 = sras_r1;
    always_comb sras_d  = refetch ? ras_op(sras_r1, r2_op, r2_val) : sras_old;
  end else begin : g_r_std
    always_comb sras_d1 = sras_old;
    always_comb sras_d  = ras_op(sras_d1, r2_op, r2_val);
  end

  always_comb begin
    spec_ck.h.head    = spec_q.head;
    spec_ck.h.fh      = spec_q.fh;
    spec_ck.r         = ras_take(sras_q);
    spec_ras_nonempty = (sras_q.cnt != '0);
    spec_ras_top      = sras_q.st[sras_q.ptr];
    spec_fh           = spec_q.fh;
    spec1_ck.h.head    = spec_d1.head;
    spec1_ck.h.fh      = spec_d1.fh;
    spec1_ck.r         = ras_take(sras_d1);
    spec1_ras_nonempty = (sras_d1.cnt != '0);
    spec1_ras_top      = sras_d1.st[sras_d1.ptr];
    spec1_fh           = spec_d1.fh;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_q <= '0;
      arch_q <= '0;
      sras_q <= '0;
      aras_q <= '0;
    end else begin
      spec_q <= spec_d;
      arch_q <= arch_d;
      sras_q <= sras_d;
      aras_q <= aras_d;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;   // refetch-only command: used only in REFONLY
  assign unused_ok = ^{h2_en, h2_bits, refetch, hr_mode, hr_ck, hr_push_en, hr_push_bits, rr_mode, rr_ck, rr_op,
                       rr_val};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
