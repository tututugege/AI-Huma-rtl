// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::decide, comb (Clean BPU v11: 1-Taken S0->S1->S2, 2A+2B)
`default_nettype none

module bpu_ctl import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic       refetch,
  input  logic       refetch_pd,
  input  logic       rep_ok_in,          // internal rec_q[256] matched rf_blk / epoch / pc
  input  logic       pd_valid,
  input  logic       pd_flush,
  input  logic       pdq_have,
  input  logic       icache_read_ready,
  /* verilator lint_off UNUSEDSIGNAL */
  input  blk_t       r0,
  input  blk_t       r1,
  input  logic       fin_diff,           // pre-evaluated pred_differs(fin, r1.g) from bpu_eval (Cut A2)
  /* verilator lint_on UNUSEDSIGNAL */
  output logic       d_valid,
  output logic       ovr,
  output logic [1:0] squash_n,
  output logic [1:0] hold_n,
  output logic       issue,
  output logic       s0_go,
  output logic       pd_restore,
  output logic       rep_ok
);

  // S2 evaluates r1; ovr squashes r0 (0..1 block)
  always_comb begin
    d_valid  = r1.valid && !refetch;
    ovr      = d_valid && fin_diff;
    squash_n = {1'b0, ovr && r0.valid};
    hold_n   = {1'b0, r0.valid && r0.sq};
  end

  // 2A+2B: no same-cycle refetch S0 issue; an S2 override recovers in the same cycle (no S0 issue)
  always_comb begin
    issue = !refetch && !ovr && icache_read_ready;
    s0_go = issue;
  end

  // Refetch priority: pd_restore > backend repair > arch rollback
  always_comb begin
    pd_restore = refetch && refetch_pd && pd_valid && pd_flush && pdq_have;
    rep_ok     = refetch && !pd_restore && rep_ok_in;
  end

endmodule

`default_nettype wire
