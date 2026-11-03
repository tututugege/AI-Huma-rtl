// Ref: back-end/Exu/include/Fu.h  MulUnit (FixedLatencyFU, latency MUL_MAX_LATENCY)
`default_nettype none

// One multiplier FU: the product is computed in the accept cycle (as in the C++ impl_compute) and travels through
// the mul_pipe result pipeline together with its write-back payload.
module mul_unit
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       en,
  input  logic                       consume,
  input  logic                       flush,
  input  logic [BR_MASK_WIDTH-1:0]   flush_mask,
  input  logic [BR_MASK_WIDTH-1:0]   clear_mask,
  input  logic [1:0]                 func3,
  input  logic [31:0]                src1_rdata,
  input  logic [31:0]                src2_rdata,
  input  logic [ROB_IDX_WIDTH-1:0]   rob_idx,
  input  logic [PRF_IDX_WIDTH-1:0]   dest_preg,
  input  logic                       dest_en,
  input  logic [BR_MASK_WIDTH-1:0]   br_mask,
  output logic                       complete,
  output logic                       ready,
  output logic [31:0]                result,
  output logic [ROB_IDX_WIDTH-1:0]   done_rob_idx,
  output logic [PRF_IDX_WIDTH-1:0]   done_dest_preg,
  output logic                       done_dest_en,
  output logic [BR_MASK_WIDTH-1:0]   done_br_mask
);

  logic [31:0] product;
  fu_uop_t     en_uop, done_uop;

  mul_core u_core (.func3(func3), .src1_rdata(src1_rdata), .src2_rdata(src2_rdata), .result(product));

  always_comb begin
    en_uop = '{result: product, rob_idx: rob_idx, dest_preg: dest_preg, dest_en: dest_en, br_mask: br_mask};
    result         = done_uop.result;
    done_rob_idx   = done_uop.rob_idx;
    done_dest_preg = done_uop.dest_preg;
    done_dest_en   = done_uop.dest_en;
    done_br_mask   = done_uop.br_mask;
  end

  mul_pipe u_pipe (
    .clk(clk), .rst_n(rst_n), .flush(flush), .flush_mask(flush_mask), .clear_mask(clear_mask),
    .en(en), .consume(consume), .en_uop(en_uop), .complete(complete), .ready(ready), .done_uop(done_uop)
  );

endmodule

`default_nettype wire
