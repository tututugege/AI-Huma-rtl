// Ref: front-end/BPU/BPU_pipe.h  State::spec / arch / sras / aras (speculative and architectural history and RAS)
`default_nettype none

// Speculative and architectural global history (256-bit ring + head + 12 folded histories) and return-address stack.
// The commit stream advances the architectural copies, one taken-branch symbol or call / return per commit lane.
// The speculative copies are updated by exactly one command per cycle (the front end's decision of the cycle):
//   history mode  HOLD: keep   PUSH: push on the current state   CK: load a checkpoint (head + folds), then push
//                 ARCH: load the architectural copy (after this cycle's commits)
//   RAS mode      same four, with ARCH = architectural stack, CK = (ptr, cnt, top) restore
module bpu_spec import bpu_pkg::*; import bpu_stage_pkg::*; (
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
  // state before this cycle's update
  output ck_t                 spec_ck,
  output logic                spec_ras_nonempty,
  output logic [31:0]         spec_ras_top,
  output fh_t                 spec_fh
);

  localparam logic [1:0] M_PUSH = 2'd1;
  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  hist_t spec_q, spec_d, arch_q, arch_d;
  ras_t  sras_q, sras_d, aras_q, aras_d;

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

  // Ref: comb: spec history update
  always_comb begin
    spec_d = spec_q;
    case (h_mode)
      M_PUSH: spec_d = hist_push_sym(spec_q, h_push_en, h_push_bits);
      M_CK:   spec_d = hist_push_sym(hist_restore(spec_q, h_ck), h_push_en, h_push_bits);
      M_ARCH: spec_d = hist_push_sym(arch_d, h_push_en, h_push_bits);
      default: spec_d = spec_q;
    endcase
  end

  // Ref: comb: spec RAS update
  always_comb begin
    sras_d = sras_q;
    case (r_mode)
      M_PUSH: sras_d = ras_op(sras_q, r_op, r_val);
      M_CK:   sras_d = ras_op(ras_restore(sras_q, r_ck), r_op, r_val);
      M_ARCH: sras_d = ras_op(aras_d, r_op, r_val);
      default: sras_d = sras_q;
    endcase
  end

  always_comb begin
    spec_ck.h.head    = spec_q.head;
    spec_ck.h.fh      = spec_q.fh;
    spec_ck.r         = ras_take(sras_q);
    spec_ras_nonempty = (sras_q.cnt != '0);
    spec_ras_top      = sras_q.st[sras_q.ptr];
    spec_fh           = spec_q.fh;
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

endmodule

`default_nettype wire
