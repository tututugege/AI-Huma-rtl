// Ref: back-end/Exu/include/AbstractFU.h  FixedLatencyFU (pipeline deque, comb_ctrl / comb_issue / comb_consume)
`default_nettype none

// Fixed-latency non-stalling pipeline of DEPTH cycles (STAGES = DEPTH - 1 shift-register stages). Per cycle:
//   1. kill      : flush/younger mispred drops in-flight entries at that stage
//   2. accept    : en shifts a new entry into stage 0
//   3. complete  : surviving stage STAGES-1 completes after DEPTH-1 register hops
module mul_pipe
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*, ttg_util_pkg::ttg_rob_younger;
#(
  parameter int DEPTH = MUL_MAX_LATENCY,
  parameter type UOP_T = fu_uop_t          // payload of an entry (rob_idx / rob_flag + result fields); the FP units use fp_uop_t
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  input  logic                     en,
  input  UOP_T                     en_uop,
  output logic                     complete,
  output UOP_T                     done_uop
);

  localparam int STAGES = DEPTH - 1;

`ifndef SYNTHESIS
  if (DEPTH < 2) begin : g_depth_check
    $error("mul_pipe: latency must be >= 2 (a latency-1 FU would complete in its accept cycle)");
  end
`endif

  // ---- state ----
  logic [STAGES-1:0] valid_q, valid_d, surv;
  UOP_T              uop_q [STAGES];
  UOP_T              uop_d [STAGES];

  always_comb begin
    for (int s = 0; s < STAGES; s++) begin
      surv[s] = valid_q[s] &&
                !(flush_all || (flush_br && ttg_rob_younger(uop_q[s].rob_idx, uop_q[s].rob_flag,
                                                            flush_rob_idx, flush_rob_flag)));
    end
    complete = surv[STAGES-1];
    done_uop = uop_q[STAGES-1];

    valid_d[0] = en;
    uop_d[0]   = en_uop;
    for (int s = 1; s < STAGES; s++) begin
      valid_d[s] = surv[s-1];
      uop_d[s]   = uop_q[s-1];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
      for (int s = 0; s < STAGES; s++) uop_q[s] <= '0;
    end else begin
      valid_q <= valid_d;
      for (int s = 0; s < STAGES; s++) uop_q[s] <= uop_d[s];
    end
  end

endmodule

`default_nettype wire
