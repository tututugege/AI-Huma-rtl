// Ref: back-end/Exu/include/Fu.h  MulUnit (FixedLatencyFU, latency MUL_MAX_LATENCY)
`default_nettype none

module mul_unit
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,
  input  logic                     consume,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  input  logic [1:0]               func3,
  input  logic                     is_word,
  input  logic [XLEN_BITS-1:0]     src1_rdata,
  input  logic [XLEN_BITS-1:0]     src2_rdata,
  input  logic [ROB_IDX_WIDTH-1:0] rob_idx,
  input  logic                     rob_flag,
  input  logic [PRF_IDX_WIDTH-1:0] dest_preg,
  input  logic                     dest_en,
  output logic                     complete,
  output logic                     ready,
  output logic [XLEN_BITS-1:0]     result,
  output logic [ROB_IDX_WIDTH-1:0] done_rob_idx,
  output logic                     done_rob_flag,
  output logic [PRF_IDX_WIDTH-1:0] done_dest_preg,
  output logic                     done_dest_en
);

  logic [XLEN_BITS-1:0] product;
  fu_uop_t     en_uop;
  /* verilator lint_off UNUSEDSIGNAL */
  fu_uop_t     done_uop;
  /* verilator lint_on UNUSEDSIGNAL */

  mul_core u_core (
    .clk(clk), .func3(func3), .is_word(is_word), .src1_rdata(src1_rdata), .src2_rdata(src2_rdata), .result(product)
  );

  always_comb begin
    en_uop         = '{result: '0, rob_idx: rob_idx, rob_flag: rob_flag, dest_preg: dest_preg, dest_en: dest_en};
    result         = product;
    done_rob_idx   = done_uop.rob_idx;
    done_rob_flag  = done_uop.rob_flag;
    done_dest_preg = done_uop.dest_preg;
    done_dest_en   = done_uop.dest_en;
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && complete && !consume) $error("mul_unit: a completed product was not consumed in its completion cycle");
`endif

  mul_pipe u_pipe (
    .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .flush_br(flush_br),
    .flush_rob_idx(flush_rob_idx), .flush_rob_flag(flush_rob_flag),
    .en(en), .consume(consume), .en_uop(en_uop), .complete(complete), .ready(ready), .done_uop(done_uop)
  );

endmodule

`default_nettype wire
