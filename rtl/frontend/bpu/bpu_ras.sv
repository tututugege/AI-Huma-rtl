// Ref: front-end/BPU/BPU.h  BPU_TOP::bpu_hist_comb (RAS part), bpu_pre_read_req_comb / bpu_data_seq_read (stack top)
`default_nettype none

// Return address stack: a speculative copy (updated by the prediction, first taken lane of a fetch group) and an
// architectural copy (updated by the committed calls/returns, up to 8 per cycle in lane order).  A refetch copies the
// NEW architectural state (after this cycle's commits) into the speculative copy.  The stack top shown to the predictor
// is the architectural one in a refetch cycle and the speculative one otherwise (start-of-cycle state).
module bpu_ras import bpu_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 refetch,
  input  logic                 spec_push,
  input  logic                 spec_pop,
  input  logic [31:0]          spec_push_val,
  input  logic                 arch_push     [NCOMMIT],
  input  logic                 arch_pop      [NCOMMIT],
  input  logic [31:0]          arch_push_val [NCOMMIT],
  output logic                 top_has,
  output logic [31:0]          top_val
);

  logic [31:0]          spec_stk_q [RAS_DEPTH];
  logic [31:0]          spec_stk_d [RAS_DEPTH];
  logic [31:0]          arch_stk_q [RAS_DEPTH];
  logic [31:0]          arch_stk_d [RAS_DEPTH];
  logic [RAS_PTR_W-1:0] spec_base_q, spec_base_d, arch_base_q, arch_base_d;
  logic [RAS_CNT_W-1:0] spec_cnt_q,  spec_cnt_d,  arch_cnt_q,  arch_cnt_d;

  // ---- architectural chain: 8 steps in lane order ----
  logic [RAS_PTR_W-1:0] a_base [NCOMMIT + 1];
  logic [RAS_CNT_W-1:0] a_cnt  [NCOMMIT + 1];
  logic                 a_we   [NCOMMIT];
  logic [RAS_PTR_W-1:0] a_slot [NCOMMIT];

  assign a_base[0] = arch_base_q;
  assign a_cnt[0]  = arch_cnt_q;
  for (genvar l = 0; l < NCOMMIT; l++) begin : g_arch
    bpu_ras_step u_step (
      .base(a_base[l]), .count(a_cnt[l]), .push(arch_push[l]), .pop(arch_pop[l]),
      .base_next(a_base[l + 1]), .count_next(a_cnt[l + 1]), .wr_en(a_we[l]), .wr_slot(a_slot[l])
    );
  end

  // ---- speculative step ----
  logic [RAS_PTR_W-1:0] s_base;
  logic [RAS_CNT_W-1:0] s_cnt;
  logic                 s_we;
  logic [RAS_PTR_W-1:0] s_slot;

  bpu_ras_step u_spec (
    .base(spec_base_q), .count(spec_cnt_q), .push(spec_push), .pop(spec_pop),
    .base_next(s_base), .count_next(s_cnt), .wr_en(s_we), .wr_slot(s_slot)
  );

  // stack contents: later lanes overwrite earlier ones; refetch copies the new architectural stack into the spec stack
  for (genvar j = 0; j < RAS_DEPTH; j++) begin : g_slot
    always_comb begin
      arch_stk_d[j] = arch_stk_q[j];
      for (int l = 0; l < NCOMMIT; l++) if (a_we[l] && a_slot[l] == RAS_PTR_W'(j)) arch_stk_d[j] = arch_push_val[l];
      spec_stk_d[j] = (s_we && s_slot == RAS_PTR_W'(j)) ? spec_push_val : spec_stk_q[j];
      if (refetch) spec_stk_d[j] = arch_stk_d[j];
    end
  end

  always_comb begin
    arch_base_d = a_base[NCOMMIT];
    arch_cnt_d  = a_cnt[NCOMMIT];
    spec_base_d = refetch ? arch_base_d : s_base;
    spec_cnt_d  = refetch ? arch_cnt_d : s_cnt;
  end

  // stack top: architectural copy in a refetch cycle, speculative otherwise (start-of-cycle values)
  logic [RAS_PTR_W-1:0] top_base;
  logic [RAS_CNT_W-1:0] top_cnt;
  logic [RAS_PTR_W-1:0] top_slot;
  always_comb begin
    top_base = refetch ? arch_base_q : spec_base_q;
    top_cnt  = refetch ? arch_cnt_q : spec_cnt_q;
    top_has  = (top_cnt != '0);
    top_slot = top_base + top_cnt[RAS_PTR_W-1:0] - RAS_PTR_W'(1);
    top_val  = top_has ? (refetch ? arch_stk_q[top_slot] : spec_stk_q[top_slot]) : 32'd0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_base_q <= '0;
      spec_cnt_q  <= '0;
      arch_base_q <= '0;
      arch_cnt_q  <= '0;
      for (int j = 0; j < RAS_DEPTH; j++) begin
        spec_stk_q[j] <= 32'd0;
        arch_stk_q[j] <= 32'd0;
      end
    end else begin
      spec_base_q <= spec_base_d;
      spec_cnt_q  <= spec_cnt_d;
      arch_base_q <= arch_base_d;
      arch_cnt_q  <= arch_cnt_d;
      for (int j = 0; j < RAS_DEPTH; j++) begin
        spec_stk_q[j] <= spec_stk_d[j];
        arch_stk_q[j] <= arch_stk_d[j];
      end
    end
  end

endmodule

`default_nettype wire
