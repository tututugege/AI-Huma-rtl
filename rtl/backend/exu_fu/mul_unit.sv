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
  input  logic                       is_word,
  input  logic [XLEN_BITS-1:0]                src1_rdata,
  input  logic [XLEN_BITS-1:0]                src2_rdata,
  input  logic [ROB_IDX_WIDTH-1:0]   rob_idx,
  input  logic [PRF_IDX_WIDTH-1:0]   dest_preg,
  input  logic                       dest_en,
  input  logic [BR_MASK_WIDTH-1:0]   br_mask,
  output logic                       complete,
  output logic                       ready,
  output logic [XLEN_BITS-1:0]                result,
  output logic [ROB_IDX_WIDTH-1:0]   done_rob_idx,
  output logic [PRF_IDX_WIDTH-1:0]   done_dest_preg,
  output logic                       done_dest_en,
  output logic [BR_MASK_WIDTH-1:0]   done_br_mask
);

  logic [XLEN_BITS-1:0] product;
  fu_uop_t     en_uop;
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: done_uop.result is unused (the product comes from the multiplier pipeline)
  fu_uop_t     done_uop;
  /* verilator lint_on UNUSEDSIGNAL */

  // the multiplier is spread over the latency (mul_core): its result of this cycle belongs to the entry that completes now
  mul_core u_core (
    .clk(clk), .func3(func3), .is_word(is_word), .src1_rdata(src1_rdata), .src2_rdata(src2_rdata), .result(product)
  );

  always_comb begin
    en_uop = '{result: '0, rob_idx: rob_idx, dest_preg: dest_preg, dest_en: dest_en, br_mask: br_mask};
    result         = product;   // (done_uop.result is unused: the product comes from the multiplier pipeline, valid when complete)
    done_rob_idx   = done_uop.rob_idx;
    done_dest_preg = done_uop.dest_preg;
    done_dest_en   = done_uop.dest_en;
    done_br_mask   = done_uop.br_mask;
  end

`ifndef SYNTHESIS
  // the result of the multiplier pipeline is lost if the completed entry is not consumed in its completion cycle
  always_ff @(posedge clk) if (rst_n && complete && !consume) $error("mul_unit: a completed product was not consumed in its completion cycle");
`endif

  mul_pipe u_pipe (
    .clk(clk), .rst_n(rst_n), .flush(flush), .flush_mask(flush_mask), .clear_mask(clear_mask),
    .en(en), .consume(consume), .en_uop(en_uop), .complete(complete), .ready(ready), .done_uop(done_uop)
  );

endmodule

`default_nettype wire
