// Ref: front-end/front_top.cpp  front_read_enable_comb, front_bpu_control_comb, front_comb_calc (S5, S9-S11, S14)
`default_nettype none

// Combinational read/write enables, BPU gating and the front2back output bypass of the front-end.
// Everything is a function of the start-of-cycle FIFO flags plus a few same-cycle producer signals.
// Simplifications against the C++ (all proven by the exhaustive replay against a literal transcription):
//  - front.in.reset (global_reset) is 1 only inside FrontTop::init(); rst_n replaces it: no "& !reset" terms;
//  - predecode_can_run already contains !f2b_full, so front2back_can_write == predecode_can_run;
//  - the bypass condition's "!saved_front2back.valid" is implied by f2b_empty (an empty queue has no head);
//  - compiled-out paths (slot1, mini flush, 2-ahead, the two icache bypasses, dummy PTAB entries) are not built.
module front_ctrl_enables import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic global_refetch,
  input  logic be_refetch,
  input  logic be_fifo_read_enable,
  input  logic icache_ready,
  input  logic fa_full,
  input  logic fa_empty,
  input  logic inst_empty,
  input  logic ptab_empty,
  input  logic f2b_full,
  input  logic f2b_empty,
  input  logic bpu_icache_read_valid,
  input  logic bpu_ptab_write_enable,
  input  logic checker_flush_enable,
  input  logic bpu_override_valid,     // S2 override of the younger block this cycle
  input  logic bpu_override_squash,    // ... and that block is in flight (its fetch address is the youngest entry)
  input  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size,
  output logic fa_rd_en,
  output logic predecode_can_run,
  output logic bpu_can_run,
  output logic bpu_icache_read_ready,
  output logic fa_wr_en,
  output logic fa_drop_tail,
  output logic ptab_wr_en,
  output logic f2b_wr_en,
  output logic f2b_use_bypass,
  output logic front_out_valid,
  output logic do_predecode_flush
);

  logic bpu_stall;
  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] squash_n;   // entries the override drops (0 or 1)
  logic f2b_head_valid;   // front2back FIFO read port shows a stored entry (its refetch is the backend's only)

  // Ref: front_read_enable_comb (fetch_addr read, predecode_can_run_old = inst FIFO / PTAB read enable)
  always_comb begin
    squash_n          = {{($bits(squash_n) - 1){1'b0}}, bpu_override_squash};
    // an override takes the youngest fetch-address entry away: do not pop it (the queue holds only that entry)
    fa_rd_en          = icache_ready && !fa_empty && !global_refetch &&
                        !(bpu_override_valid && fa_size <= squash_n);
    // FE_RFAST bit1: the block leaving the BPU's last stage is written into the PTAB and may be read by the checker in the same cycle
    predecode_can_run = !inst_empty && (!ptab_empty || ((FE_RFAST & 2) != 0 && bpu_ptab_write_enable)) && !f2b_full &&
                        !global_refetch;
  end

  // Ref: front_bpu_control_comb; S5 (fetch_addr write); S9 (PTAB write)
  always_comb begin
    bpu_stall             = fa_full;      // PTAB overflow is prevented by the BPU credit (ptab_size)
    bpu_can_run           = !bpu_stall || global_refetch;
    bpu_icache_read_ready = !fa_full && bpu_can_run;
    fa_wr_en              = bpu_icache_read_valid && bpu_can_run;
    ptab_wr_en            = bpu_ptab_write_enable && !global_refetch;
    fa_drop_tail          = bpu_override_squash;
  end

  // Ref: S10 (flush decision), S11 (front2back write / output bypass), S14 (output valid)
  always_comb begin
    do_predecode_flush = predecode_can_run && checker_flush_enable;
    f2b_use_bypass     = be_fifo_read_enable && f2b_empty && predecode_can_run;
    f2b_wr_en          = predecode_can_run && !f2b_use_bypass;
    f2b_head_valid     = be_fifo_read_enable && !be_refetch && !f2b_empty;
    front_out_valid    = f2b_head_valid || f2b_use_bypass;
  end

endmodule

`default_nettype wire
