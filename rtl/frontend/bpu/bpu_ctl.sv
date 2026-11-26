// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::decide, comb (S2->S3 split: refetch > S3 ovr > S0 issue; no l1_ov)
`default_nettype none

module bpu_ctl import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic        refetch,
  input  logic        refetch_pd,
  input  logic        rep_ok_in,          // internal rec_q[256] matched rf_blk / epoch / pc
  input  logic        pd_valid,
  input  logic        pd_flush,
  input  logic        pdq_have,
  input  logic        icache_read_ready,
  /* verilator lint_off UNUSEDSIGNAL */
  input  blk_t        r0,
  input  blk_t        r1,
  input  blk_t        r2,
  input  pred_t       fin,
  input  pred_t       fin_b,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic        d_valid,
  output logic        ovr_a,
  output logic        d_pair,
  output logic        ovr_b,
  output logic        ovr,
  output logic [1:0]  squash_n,
  output logic [1:0]  hold_n,
  output logic        issue,
  output logic        fast,
  output logic        s0_go,
  output logic        pd_restore,
  output logic        rep_ok
);

  // Ref: decide (S3 evaluates r2; ovr squashes r0 and/or r1 -> squash_n in 0..2)
  always_comb begin
    d_valid  = r2.valid && !refetch;
    ovr_a    = d_valid && pred_differs(fin, r2.g, r2.has_b);
    d_pair   = d_valid && !ovr_a && r2.has_b;
    ovr_b    = d_pair && pred_differs(fin_b, r2.g_b, 1'b0);
    ovr      = ovr_a || ovr_b;
    squash_n = ovr ? ({1'b0, r0.valid} + {1'b0, r1.valid}) : 2'd0;
    hold_n   = {1'b0, (r0.valid && r0.sq)} + {1'b0, (r1.valid && r1.sq)};
  end

  // Ref: comb, S0 credit gated by Unified FTQ-64 icache_read_ready (v10: never paused by training!)
  always_comb begin
    issue = !refetch && !ovr && icache_read_ready;
    fast  = refetch && icache_read_ready;
    s0_go = issue || fast;
  end

  // Ref: comb, refetch handling
  always_comb begin
    pd_restore = refetch && refetch_pd && pd_valid && pd_flush && pdq_have;
    rep_ok     = refetch && !pd_restore && rep_ok_in;
  end

endmodule

`default_nettype wire
