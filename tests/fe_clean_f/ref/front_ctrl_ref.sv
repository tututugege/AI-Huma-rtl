// Ref: front-end/front_top.cpp  FrontControl (control / enables / refetch_ctrl)
`default_nettype none

// Front-end control: global refetch, Unified FTQ-64 / inst_fifo_ref enables, BPU gating, predecode flush.
module front_ctrl_ref import ttg_cfg_pkg::*; import front_pkg::*; (
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

  front_refetch_ctrl_ref u_refetch (
    .clk, .rst_n,
    .be_refetch, .be_refetch_address,
    .do_predecode_flush,
    .predecode_flush_address (checker_flush_address),
    .global_refetch, .refetch_address
  );

  front_ctrl_enables_ref u_enables (
    .global_refetch, .be_fifo_read_enable, .icache_ready,
    .ftq_full, .ifu_empty, .ifu_cnt_sat, .bpu_hold_n, .inst_empty, .inst_fifo_room, .s2_empty,
    .bpu_icache_read_valid, .bpu_s2_wr_req, .checker_flush_enable, .bpu_override_squash_n,
    .ifu_rd_en, .predecode_can_run, .bpu_icache_read_ready,
    .s0_wr_en, .s0_drop_tail_n, .s2_wr_en, .do_predecode_flush
  );

endmodule

`default_nettype wire
