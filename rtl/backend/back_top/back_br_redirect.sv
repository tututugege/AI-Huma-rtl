// Ref: back-end/Idu.cpp  class Idu (br_latch -> backend branch redirect register stage)
`default_nettype none

// One-cycle registered branch mispredict redirect stage in back_top (between EXU and FTQ/back-end flush).
module back_br_redirect import ttg_cfg_pkg::*; (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        rob_flush,
  input  logic                        exu_mispred,
  input  logic [XLEN_BITS-1:0]        exu_redirect_pc,
  input  logic [ROB_IDX_WIDTH-1:0]    exu_redirect_rob_idx,
  input  logic                        exu_redirect_rob_flag,
  input  logic [FTQ_IDX_WIDTH-1:0]    exu_ftq_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] exu_ftq_offset,
  input  logic [XLEN_BITS-1:0]        exu_br_pc,
  input  logic                        exu_br_is_rvc,
  output logic                        mispred,
  output logic [XLEN_BITS-1:0]        redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx,
  output logic                        redirect_rob_flag,
  output logic [FTQ_IDX_WIDTH-1:0]    ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset,
  output logic [XLEN_BITS-1:0]        br_pc,
  output logic                        br_is_rvc
);

  logic                        mispred_q;
  logic [XLEN_BITS-1:0]        redirect_pc_q;
  logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx_q;
  logic                        redirect_rob_flag_q;
  logic [FTQ_IDX_WIDTH-1:0]    ftq_idx_q;
  logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset_q;
  logic [XLEN_BITS-1:0]        br_pc_q;
  logic                        br_is_rvc_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mispred_q           <= 1'b0;
      redirect_pc_q       <= '0;
      redirect_rob_idx_q  <= '0;
      redirect_rob_flag_q <= 1'b0;
      ftq_idx_q           <= '0;
      ftq_offset_q        <= '0;
      br_pc_q             <= '0;
      br_is_rvc_q         <= 1'b0;
    end else begin
      mispred_q           <= exu_mispred & ~rob_flush;
      redirect_pc_q       <= exu_redirect_pc;
      redirect_rob_idx_q  <= exu_redirect_rob_idx;
      redirect_rob_flag_q <= exu_redirect_rob_flag;
      ftq_idx_q           <= exu_ftq_idx;
      ftq_offset_q        <= exu_ftq_offset;
      br_pc_q             <= exu_br_pc;
      br_is_rvc_q         <= exu_br_is_rvc;
    end
  end

  assign mispred           = mispred_q;
  assign redirect_pc       = redirect_pc_q;
  assign redirect_rob_idx  = redirect_rob_idx_q;
  assign redirect_rob_flag = redirect_rob_flag_q;
  assign ftq_idx           = ftq_idx_q;
  assign ftq_offset        = ftq_offset_q;
  assign br_pc             = br_pc_q;
  assign br_is_rvc         = br_is_rvc_q;

endmodule

`default_nettype wire
