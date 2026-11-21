// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::decide, l1_override, comb (priority of refetch / override / issue)
`default_nettype none

module bpu_ctl import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic        refetch,
  input  logic        refetch_pd,
  input  logic        rep_ok_in,          // internal rec_q[256] matched rf_blk / epoch / pc
  input  logic        pd_valid,
  input  logic        pd_flush,
  input  logic        pdq_have,
  input  logic        icache_read_ready,
  input  logic [7:0]  ptab_size,
  /* verilator lint_off UNUSEDSIGNAL */
  input  blk_t        r0,
  input  blk_t        r1,
  input  pred_t       fin,
  input  pred_t       fin_b,
  input  pred_t       g1,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic        d_valid,
  output logic        ovr_a,
  output logic        d_pair,
  output logic        ovr_b,
  output logic        ovr,
  output logic        squash,
  output logic        l1_ov,
  output logic        issue,
  output logic        fast,
  output logic        s0_go,
  output logic        pd_restore,
  output logic        rep_ok
);

  logic ptab_stall;
  localparam bit RF0   = (FE_RFAST & 1) != 0;
  localparam bit BF_L1 = (FE_BFAST & 1) != 0;
  localparam bit BF_SD = (FE_BFAST & 2) != 0;

  // Ref: decide / l1_override (2-taken: ovr_a checks slot/taken when has_b; ovr_b checks Block B when !ovr_a)
  always_comb begin
    d_valid = r1.valid && !refetch;
    ovr_a   = d_valid && pred_differs(fin, r1.g, r1.has_b);
    d_pair  = d_valid && !ovr_a && r1.has_b;
    ovr_b   = d_pair && pred_differs(fin_b, r1.g_b, 1'b0);
    ovr     = ovr_a || ovr_b;
    squash  = ovr && r0.valid;
    l1_ov   = !refetch && !ovr && r0.valid && !r0.ah_hit && g1.hit && pred_differs(g1, r0.g, r0.has_b);
  end

  // Ref: comb, S0 credit: blocks in flight count against the PTAB
  always_comb begin
    ptab_stall = icache_read_ready &&
                 (int'(ptab_size) + int'(r0.valid) + int'(r1.valid) >= PTAB_SIZE - 1);
    issue      = !refetch && !ovr && !l1_ov && icache_read_ready && !ptab_stall;
    fast       = icache_read_ready &&
                 ((RF0 && refetch) ||
                  (((BF_SD && ovr) || (BF_L1 && l1_ov)) && (int'(ptab_size) + 1 < PTAB_SIZE - 1)));
    s0_go      = issue || fast;
  end

  // Ref: comb, refetch handling
  always_comb begin
    pd_restore = refetch && refetch_pd && pd_valid && pd_flush && pdq_have;
    rep_ok     = refetch && !pd_restore && rep_ok_in;
  end

endmodule

`default_nettype wire
