// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::decide, l1_override, comb (priority of refetch / override / issue)
`default_nettype none

// Decisions of the cycle, from registers and the compare-stage result only.
//   ovr      the block in S2 disagrees with its S0 / S1 guess: younger blocks are squashed, S0 restarts at its
//            target.
//   l1_ov    the L1 table (S1) hits and disagrees with the S0 guess of the block in S1: that block gets the L1
//            guess and S0 does not issue this cycle (one bubble instead of two).
//   issue    S0 sends the block at the pc register to the ICache (fetch-address queue) and to S1.
//   Priority: refetch > ovr > l1_ov > issue.  A predecode flush with a PDCKPT record restores from the record, a
//   back-end branch mispredict from the checkpoint the FTQ returned (same epoch), anything else from the
//   committed state.
module bpu_ctl import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic        refetch,
  input  logic        refetch_pd,         // the refetch comes from the predecode checker
  input  logic        rf_valid,           // back-end refetch caused by a branch mispredict
  input  logic        rf_epoch_ok,        // the returned checkpoint belongs to the current history epoch
  input  logic        pd_valid,
  input  logic        pd_flush,
  input  logic        pdq_have,
  input  logic        icache_read_ready,
  input  logic [7:0]  ptab_size,
  /* verilator lint_off UNUSEDSIGNAL */   // block / guess structs: only some fields are decisions here
  input  blk_t        r0,
  input  blk_t        r1,
  input  pred_t       fin,
  input  pred_t       g1,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic        d_valid,
  output logic        ovr,
  output logic        squash,
  output logic        l1_ov,
  output logic        issue,
  output logic        pd_restore,
  output logic        rep_ok
);

  logic ptab_stall;

  // Ref: decide / l1_override
  always_comb begin
    d_valid = r1.valid && !refetch;
    ovr     = d_valid && pred_differs(fin, r1.g);
    squash  = ovr && r0.valid;
    l1_ov   = !refetch && !ovr && r0.valid && g1.hit && pred_differs(g1, r0.g);
  end

  // Ref: comb, S0 credit: blocks in flight count against the PTAB
  always_comb begin
    ptab_stall = icache_read_ready &&
                 (int'(ptab_size) + int'(r0.valid) + int'(r1.valid) >= PTAB_SIZE - 1);
    issue      = !refetch && !ovr && !l1_ov && icache_read_ready && !ptab_stall;
  end

  // Ref: comb, refetch handling
  always_comb begin
    pd_restore = refetch && refetch_pd && pd_valid && pd_flush && pdq_have;
    rep_ok     = refetch && !pd_restore && rf_valid && rf_epoch_ok;
  end

endmodule

`default_nettype wire
