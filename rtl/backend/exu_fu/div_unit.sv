// Ref: back-end/Exu/include/Fu.h  DivUnit (IterativeFU, variable-latency Radix-16 early-out divider)
`default_nettype none

module div_unit
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int LAT = DIV_MAX_LATENCY
) (
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
  output logic                     wb_next,
  output logic                     wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg,
  output logic [XLEN_BITS-1:0]     result,
  output logic [ROB_IDX_WIDTH-1:0] done_rob_idx,
  output logic                     done_rob_flag,
  output logic [PRF_IDX_WIDTH-1:0] done_dest_preg,
  output logic                     done_dest_en
);

  localparam int CW = 5;

  logic       accept, run;
  logic [4:0] lat_m1;

  exu_iter_ctl #(.CW(CW)) u_ctl (
    .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .flush_br(flush_br),
    .flush_rob_idx(flush_rob_idx), .flush_rob_flag(flush_rob_flag),
    .en(en), .consume(consume), .en_rob_idx(rob_idx), .en_rob_flag(rob_flag),
    .lat_m1(lat_m1),
    .accept(accept), .run(run), .complete(complete), .wb_next(wb_next), .ready(ready), .done_rob_flag(done_rob_flag)
  );

  div_core #(.LAT(LAT)) u_core (
    .clk(clk), .rst_n(rst_n), .accept(accept), .run(run), .func3(func3), .is_word(is_word),
    .src1_rdata(src1_rdata), .src2_rdata(src2_rdata), .lat_m1(lat_m1), .result(result)
  );

  logic [ROB_IDX_WIDTH-1:0] rob_idx_q;
  logic [PRF_IDX_WIDTH-1:0] dest_preg_q;
  logic                     dest_en_q;

  always_comb begin
    done_rob_idx   = rob_idx_q;
    done_dest_preg = dest_preg_q;
    done_dest_en   = dest_en_q;
    wake_valid     = wb_next && dest_en_q;
    wake_preg      = dest_preg_q;
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
