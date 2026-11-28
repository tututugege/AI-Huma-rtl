// Ref: front-end/front_top.cpp  FrontControl (control / enables / refetch_ctrl), front_global_control_comb,
// predecode_refetch / predecode_refetch_address, BpuPipe::comb_front, FrontControl::finish
`default_nettype none

// Front-end control: global refetch, Unified FTQ-64 / inst_fifo enables, BPU gating, predecode flush.
// The only state is the delayed predecode refetch (the checker found a wrong prediction last cycle): one flag plus
// the corrected fetch address, loaded at the end of the cycle that decided the flush.  The rest is combinational
// (no ptab_bypass, no front2back_fifo, explicit inst_fifo backpressure on ifu_ptr).
module front_ctrl import ttg_cfg_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        be_refetch,
  input  logic [XLEN_BITS-1:0] be_refetch_address,
  input  logic        be_fifo_read_enable,
  input  logic        icache_ready,
  input  logic        ftq_full,
  input  logic        ifu_empty,
  input  logic [1:0]  ifu_cnt_sat,
  input  logic [1:0]  bpu_hold_n,
  input  logic        inst_empty,
  input  logic        inst_fifo_room,
  input  logic        s2_empty,
  input  logic        bpu_icache_read_valid,
  input  logic        bpu_s2_wr_req,
  input  logic        checker_flush_enable,
  input  logic [1:0]  bpu_override_squash_n,
  input  logic [XLEN_BITS-1:0] checker_flush_address,
  output logic        global_refetch,
  output logic [XLEN_BITS-1:0] refetch_address,
  output logic        ifu_rd_en,
  output logic        predecode_can_run,
  output logic        bpu_icache_read_ready,
  output logic        s0_wr_en,
  output logic [1:0]  s0_drop_tail_n,
  output logic        s2_wr_en,
  output logic        do_predecode_flush
);

  // ---- global refetch: the back end wins the address select (Ref: front_global_control_comb) ----
  logic                 predecode_refetch_q;
  logic [XLEN_BITS-1:0] predecode_refetch_address_q;

  always_comb begin
    global_refetch  = be_refetch || predecode_refetch_q;
    refetch_address = be_refetch ? be_refetch_address : predecode_refetch_address_q;
  end

  // Ref: front_comb_calc S12 (next_predecode_refetch).  The C++ also zeroes the address when there is no flush; the
  // address is only read while predecode_refetch_q is set (BPU: refetch ? refetch_address : ..., BPU.h:820,1779), so
  // it is simply loaded every cycle.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      predecode_refetch_q         <= 1'b0;
      predecode_refetch_address_q <= '0;
    end else begin
      predecode_refetch_q         <= do_predecode_flush;
      predecode_refetch_address_q <= checker_flush_address;
    end
  end

  // ---- enables (Ref: FrontControl::enables, BpuPipe::comb_front, FrontControl::finish) ----
  logic bpu_stall, bpu_can_run;

  always_comb begin
    ifu_rd_en             = icache_ready && !ifu_empty && !global_refetch && (ifu_cnt_sat > bpu_hold_n)
                            && inst_fifo_room;
    predecode_can_run     = be_fifo_read_enable && !inst_empty && !s2_empty && !global_refetch;
    bpu_stall             = ftq_full;
    bpu_can_run           = !bpu_stall || global_refetch;
    bpu_icache_read_ready = !bpu_stall;
    s0_wr_en              = bpu_icache_read_valid && bpu_can_run;
    s2_wr_en              = bpu_s2_wr_req && !global_refetch;
    s0_drop_tail_n        = global_refetch ? 2'd0 : bpu_override_squash_n;
    do_predecode_flush    = predecode_can_run && checker_flush_enable;
  end

endmodule

`default_nettype wire
