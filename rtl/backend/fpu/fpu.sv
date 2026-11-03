// Ref: back-end/Exu/include/FPU.h  class FPUSoftfloat : IterativeFU   (one FPU instance, fu_idx 5 of Exu::units)
`default_nettype none

// Floating-point unit. Port adaptation only: decode -> {ctrl, slot} -> compute.
// Boundary = AbstractFU::FuInput (in_*) / FuOutput (out_*) of one FU. The uop's `op` is always UOP_FP at this FU
// (the issue port only routes OP_MASK_FP uops here) and the Exu-side pass-through fields it does not read are omitted.
module fpu
  import ttg_cfg_pkg::*;
  import fpu_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     in_en,
  input  logic                     in_consume,
  input  logic                     in_flush,
  input  logic [BR_MASK_WIDTH-1:0] in_flush_mask,
  input  logic [BR_MASK_WIDTH-1:0] in_clear_mask,
  input  logic [2:0]               in_inst_func3,
  input  logic [6:0]               in_inst_func7,
  input  logic                     in_inst_imm_rs2_bit0,   // imm[0]: signed (0) / unsigned (1) fcvt
  input  logic [31:0]              in_inst_src1_rdata,
  input  logic [31:0]              in_inst_src2_rdata,
  input  logic [BR_MASK_WIDTH-1:0] in_inst_br_mask,
  input  logic [PRF_IDX_WIDTH-1:0] in_inst_dest_preg,
  input  logic                     in_inst_dest_en,
  input  logic [ROB_IDX_WIDTH-1:0] in_inst_rob_idx,
  output logic                     out_ready,
  output logic                     out_complete,
  output logic [31:0]              out_inst_result,
  output logic [BR_MASK_WIDTH-1:0] out_inst_br_mask,
  output logic [PRF_IDX_WIDTH-1:0] out_inst_dest_preg,
  output logic                     out_inst_dest_en,
  output logic [ROB_IDX_WIDTH-1:0] out_inst_rob_idx
);

  logic [NKIND-1:0]     kind_in, kind;
  logic [LAT_W-1:0]     latency_minus_1;
  logic                 accept;
  logic [2:0]           func3_held;
  logic [31:0]          src1_held, src2_held;

  fpu_decode u_decode (.func7(in_inst_func7), .func3(in_inst_func3), .rs2_bit0(in_inst_imm_rs2_bit0), .kind(kind_in),
                       .latency_minus_1(latency_minus_1));

  fpu_ctrl u_ctrl (.clk(clk), .rst_n(rst_n), .en(in_en), .consume(in_consume), .flush(in_flush),
                   .flush_mask(in_flush_mask), .clear_mask(in_clear_mask), .in_br_mask(in_inst_br_mask),
                   .latency_minus_1(latency_minus_1), .accept(accept), .complete(out_complete), .ready(out_ready),
                   .held_br_mask(out_inst_br_mask));

  fpu_slot u_slot (.clk(clk), .rst_n(rst_n), .accept(accept), .kind_in(kind_in), .func3_in(in_inst_func3),
                   .src1_in(in_inst_src1_rdata), .src2_in(in_inst_src2_rdata), .dest_preg_in(in_inst_dest_preg),
                   .dest_en_in(in_inst_dest_en), .rob_idx_in(in_inst_rob_idx), .kind(kind), .func3(func3_held),
                   .src1(src1_held), .src2(src2_held), .dest_preg(out_inst_dest_preg), .dest_en(out_inst_dest_en),
                   .rob_idx(out_inst_rob_idx));

  fpu_compute u_compute (.kind(kind), .func3(func3_held), .a(src1_held), .b(src2_held), .result(out_inst_result));

endmodule

`default_nettype wire
