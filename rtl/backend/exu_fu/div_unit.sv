// Ref: back-end/Exu/include/Fu.h  DivUnit (IterativeFU, latency DIV_MAX_LATENCY)
`default_nettype none

// One divider FU = iterative control skeleton (exu_iter_ctl) + iterative divider datapath (div_core) + the write-back
// payload of the uop in flight (loaded on accept; br_mask lives in the skeleton because flush/clear act on it).
module div_unit
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int LAT = DIV_MAX_LATENCY
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       en,
  input  logic                       consume,
  input  logic                       flush,
  input  logic [BR_MASK_WIDTH-1:0]   flush_mask,
  input  logic [BR_MASK_WIDTH-1:0]   clear_mask,
  input  logic [1:0]                 func3,
  input  logic                       is_word,   // rv64 divw/divuw/remw/remuw: half the iterations
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

  localparam int CW = $clog2(LAT);

  logic accept, run;

  exu_iter_ctl #(.CW(CW)) u_ctl (
    .clk(clk), .rst_n(rst_n), .flush(flush), .flush_mask(flush_mask), .clear_mask(clear_mask),
    .en(en), .consume(consume), .en_br_mask(br_mask),
    .lat_m1(is_word && XLEN_BITS == 64 ? CW'(LAT / 2 - 1) : CW'(LAT - 1)),
    .accept(accept), .run(run), .complete(complete), .ready(ready), .done_br_mask(done_br_mask)
  );

  div_core #(.LAT(LAT)) u_core (
    .clk(clk), .rst_n(rst_n), .accept(accept), .run(run), .func3(func3), .is_word(is_word),
    .src1_rdata(src1_rdata), .src2_rdata(src2_rdata), .result(result)
  );

  // payload of the uop in flight: captured when it is accepted
  logic [ROB_IDX_WIDTH-1:0] rob_idx_q;
  logic [PRF_IDX_WIDTH-1:0] dest_preg_q;
  logic                     dest_en_q;

  always_comb begin
    done_rob_idx   = rob_idx_q;
    done_dest_preg = dest_preg_q;
    done_dest_en   = dest_en_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rob_idx_q   <= '0;
      dest_preg_q <= '0;
      dest_en_q   <= 1'b0;
    end else if (accept) begin
      rob_idx_q   <= rob_idx;
      dest_preg_q <= dest_preg;
      dest_en_q   <= dest_en;
    end
  end

endmodule

`default_nettype wire
