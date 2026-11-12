// Ref: back-end/Exu/include/Fu.h  FuKind::FDIV (ITER: one instruction at a time, latency by operation and format)
`default_nettype none

// The F/D divide / square-root unit: iterative control skeleton (exu_iter_ctl) with a per-operation latency, the result
// computed at accept and held with the write-back payload of the uop in flight.
module fp_div_unit
  import ttg_cfg_pkg::*;
  import fp_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       en,
  input  logic                       consume,
  input  logic                       flush,
  input  logic [BR_MASK_WIDTH-1:0]   flush_mask,
  input  logic [BR_MASK_WIDTH-1:0]   clear_mask,
  input  logic [2:0]                 func3,
  input  logic [6:0]                 func7,
  input  logic [31:0]                imm,
  input  logic [XLEN_BITS-1:0]       src1_rdata,
  input  logic [63:0]                fsrc1,
  input  logic [63:0]                fsrc2,
  input  logic [63:0]                fsrc3,
  input  logic [2:0]                 frm,
  input  logic [ROB_IDX_WIDTH-1:0]   rob_idx,
  input  logic [PRF_IDX_WIDTH-1:0]   dest_preg,
  input  logic                       dest_en,
  input  logic [BR_MASK_WIDTH-1:0]   br_mask,
  output logic                       complete,
  output logic                       ready,
  output logic [63:0]                fresult,
  output logic [4:0]                 fflags,
  output logic [ROB_IDX_WIDTH-1:0]   done_rob_idx,
  output logic [PRF_IDX_WIDTH-1:0]   done_dest_preg,
  output logic                       done_dest_en,
  output logic [BR_MASK_WIDTH-1:0]   done_br_mask
);

  logic accept, unused_run;   // run: the datapath is combinational here
  logic [63:0] res;
  logic [4:0]  flags;

  exu_iter_ctl #(.CW(FP_LAT_W)) u_ctl (
    .clk(clk), .rst_n(rst_n), .flush(flush), .flush_mask(flush_mask), .clear_mask(clear_mask),
    .en(en), .consume(consume), .en_br_mask(br_mask),
    .lat_m1(FP_LAT_W'(fp_div_latency(func7) - 1)),
    .accept(accept), .run(unused_run), .complete(complete), .ready(ready), .done_br_mask(done_br_mask)
  );

  fp_core u_core (
    .func3(func3), .imm(imm), .int_src(src1_rdata), .fsrc1(fsrc1), .fsrc2(fsrc2), .fsrc3(fsrc3), .frm(frm),
    .result(res), .fflags(flags)
  );

  // payload of the uop in flight, captured when it is accepted
  logic [63:0]              res_q;
  logic [4:0]               flags_q;
  logic [ROB_IDX_WIDTH-1:0] rob_idx_q;
  logic [PRF_IDX_WIDTH-1:0] dest_preg_q;
  logic                     dest_en_q;
  always_comb begin
    fresult        = res_q;
    fflags         = flags_q;
    done_rob_idx   = rob_idx_q;
    done_dest_preg = dest_preg_q;
    done_dest_en   = dest_en_q;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      res_q       <= '0;
      flags_q     <= '0;
      rob_idx_q   <= '0;
      dest_preg_q <= '0;
      dest_en_q   <= 1'b0;
    end else if (accept) begin
      res_q       <= res;
      flags_q     <= flags;
      rob_idx_q   <= rob_idx;
      dest_preg_q <= dest_preg;
      dest_en_q   <= dest_en;
    end
  end

endmodule

`default_nettype wire
