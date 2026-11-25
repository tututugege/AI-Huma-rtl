// Ref: back-end/Idu.cpp  class Idu::branch
`default_nettype none

module idu_bcast import ttg_cfg_pkg::*; (
  input  logic                     latch_mispred,
  input  logic [ROB_IDX_WIDTH-1:0] latch_redirect_rob_idx,
  input  logic                     latch_redirect_rob_flag,
  output logic                     mispred,
  output logic [ROB_IDX_WIDTH-1:0] redirect_rob_idx,
  output logic                     redirect_rob_flag
);

  always_comb begin
    mispred           = latch_mispred;
    redirect_rob_idx  = latch_redirect_rob_idx;
    redirect_rob_flag = latch_redirect_rob_flag;
  end

endmodule

`default_nettype wire
