// Ref: front-end/front_top.cpp  FrontControl::enables, BpuPipe::comb_front, FrontControl::finish
`default_nettype none

// Combinational read/write enables and BPU gating of the Unified FTQ-64 front end
// (no ptab_bypass, no front2back_fifo, explicit inst_fifo backpressure on ifu_ptr).
module front_ctrl_enables import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic global_refetch,
  input  logic be_fifo_read_enable,
  input  logic icache_ready,
  input  logic ftq_full,
  input  logic fa_empty,
  input  logic fa_head_fresh,
  input  logic inst_empty,
  input  logic inst_fifo_room,
  input  logic s2_empty,
  input  logic bpu_icache_read_valid,
  input  logic bpu_ptab_write_enable,
  input  logic checker_flush_enable,
  input  logic bpu_override_squash,
  output logic fa_rd_en,
  output logic predecode_can_run,
  output logic bpu_can_run,
  output logic bpu_icache_read_ready,
  output logic fa_wr_en,
  output logic fa_drop_tail,
  output logic s2_wr_en,
  output logic do_predecode_flush
);

  logic bpu_stall;

  always_comb begin
    fa_rd_en              = icache_ready && !fa_empty && !global_refetch && !fa_head_fresh && inst_fifo_room;
    predecode_can_run     = be_fifo_read_enable && !inst_empty && !s2_empty && !global_refetch;
    bpu_stall             = ftq_full;
    bpu_can_run           = !bpu_stall || global_refetch;
    bpu_icache_read_ready = !bpu_stall;
    fa_wr_en              = bpu_icache_read_valid && bpu_can_run;
    s2_wr_en              = bpu_ptab_write_enable && !global_refetch;
    fa_drop_tail          = bpu_override_squash && !global_refetch;
    do_predecode_flush    = predecode_can_run && checker_flush_enable;
  end

endmodule

`default_nettype wire
