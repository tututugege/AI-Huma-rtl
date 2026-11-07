// Ref: front-end/front_top.cpp  front_comb_calc (S1, S2, S4, S5, S9-S12, S14 control part)
`default_nettype none

// Front-end control: global refetch, FIFO read/write enables, BPU gating, front2back output bypass, predecode flush.
// Top level only wires the registered delayed-refetch block and the combinational enable block.
module front_ctrl import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        be_refetch,
  input  logic [31:0] be_refetch_address,
  input  logic        be_fifo_read_enable,
  input  logic        icache_ready,
  input  logic        fa_full,
  input  logic        fa_empty,
  input  logic        inst_empty,
  input  logic        ptab_empty,
  input  logic        f2b_full,
  input  logic        f2b_empty,
  input  logic        bpu_icache_read_valid,
  input  logic        bpu_ptab_write_enable,
  input  logic        checker_flush_enable,
  input  logic        bpu_override_valid,
  input  logic        bpu_override_squash,
  input  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size,
  input  logic [31:0] checker_flush_address,
  output logic        global_refetch,
  output logic [31:0] refetch_address,
  output logic        fa_rd_en,
  output logic        predecode_can_run,
  output logic        bpu_can_run,
  output logic        bpu_icache_read_ready,
  output logic        fa_wr_en,
  output logic        fa_drop_tail,
  output logic        ptab_wr_en,
  output logic        f2b_wr_en,
  output logic        f2b_use_bypass,
  output logic        front_out_valid,
  output logic        do_predecode_flush
);

  front_refetch_ctrl u_refetch (
    .clk, .rst_n,
    .be_refetch, .be_refetch_address,
    .do_predecode_flush,
    .predecode_flush_address (checker_flush_address),
    .global_refetch, .refetch_address
  );

  front_ctrl_enables u_enables (
    .global_refetch, .be_refetch, .be_fifo_read_enable, .icache_ready,
    .fa_full, .fa_empty, .inst_empty, .ptab_empty, .f2b_full, .f2b_empty,
    .bpu_icache_read_valid, .bpu_ptab_write_enable, .checker_flush_enable,
    .bpu_override_valid, .bpu_override_squash, .fa_size,
    .fa_rd_en, .predecode_can_run, .bpu_can_run, .bpu_icache_read_ready,
    .fa_wr_en, .fa_drop_tail, .ptab_wr_en, .f2b_wr_en, .f2b_use_bypass, .front_out_valid, .do_predecode_flush
  );

endmodule

`default_nettype wire
