// Ref: back-end/Isu.cpp  Isu::comb_calc_latency_next / comb_flush (mul_wake_pipe)
`default_nettype none

module isu_wake_mul
  import ttg_cfg_pkg::*;
  import isu_pkg::*, ttg_util_pkg::ttg_rob_younger;
#(
  parameter int SLOTS = 2,
  parameter int DEPTH = MUL_DEPTH,
  parameter int NREQ  = 2,
  parameter int CN_W  = LSU_LDU_COUNT
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [NREQ-1:0]          req_valid,
  input  logic [PRF_IDX_WIDTH-1:0] req_preg [NREQ],
  input  logic [ROB_IDX_WIDTH-1:0] req_rob_idx [NREQ],
  input  logic [NREQ-1:0]          req_rob_flag,
  input  logic [NREQ-1:0]          req_lane,
  input  logic [CN_W-1:0]          req_spec_mask [NREQ],
  input  logic [CN_W-1:0]          cn_port_mask,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  output logic [SLOTS-1:0]         wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [SLOTS],
  output logic [SLOTS-1:0]         wake_lane
);

  localparam int RPW = 1 + ROB_IDX_WIDTH;
  localparam int DW  = 1 + CN_W + PRF_IDX_WIDTH + RPW;

  logic [SLOTS-1:0] alloc_slot [NREQ];
  logic [DW-1:0]    req_bits [NREQ];
  logic [DW-1:0]    stage_bits  [DEPTH][SLOTS];
  logic [SLOTS-1:0] stage_valid [DEPTH];

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    assign req_bits[r] = {req_lane[r], req_spec_mask[r], req_preg[r], req_rob_flag[r], req_rob_idx[r]};
  end

  isu_alloc_chain #(.NREQ(NREQ), .NSLOT(SLOTS)) u_alloc (
    .clk(clk), .req(req_valid), .free({SLOTS{1'b1}}), .slot_onehot(alloc_slot));

  for (genvar s = 0; s < DEPTH; s++) begin : g_stage
    for (genvar j = 0; j < SLOTS; j++) begin : g_slot
      logic          valid_q, valid_d;
      logic [DW-1:0] bits_q;
      logic          enter_valid;
      logic [DW-1:0] enter_bits;
      logic          killed;

      if (s == 0) begin : g_first
        logic [NREQ-1:0] hit;
        for (genvar r = 0; r < NREQ; r++) begin : g_hit
          assign hit[r] = alloc_slot[r][j];
        end
        ttg_onehot_mux #(.N(NREQ), .W(DW)) u_new (.sel(hit), .data(req_bits), .out(enter_bits));
        assign enter_valid = |hit;
      end else begin : g_shift
        logic [CN_W-1:0] prev_spec;
        assign prev_spec   = stage_bits[s - 1][j][RPW + PRF_IDX_WIDTH +: CN_W];
        assign enter_valid = stage_valid[s - 1][j] && !(|(prev_spec & cn_port_mask));
        assign enter_bits  = {stage_bits[s - 1][j][DW - 1], {CN_W{1'b0}}, stage_bits[s - 1][j][RPW + PRF_IDX_WIDTH - 1 : 0]};
      end

      always_comb begin
        killed  = flush_br && ttg_rob_younger(enter_bits[ROB_IDX_WIDTH-1:0], enter_bits[ROB_IDX_WIDTH],
                                              flush_rob_idx, flush_rob_flag);
        valid_d = enter_valid && !flush_all && !killed;
      end

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          valid_q <= 1'b0;
          bits_q  <= '0;
        end else begin
          valid_q <= valid_d;
          bits_q  <= enter_bits;
        end
      end
      assign stage_valid[s][j] = valid_q;
      assign stage_bits[s][j]  = bits_q;
    end
  end

  for (genvar j = 0; j < SLOTS; j++) begin : g_out
    logic [CN_W-1:0] last_spec;
    assign last_spec     = stage_bits[DEPTH - 1][j][RPW + PRF_IDX_WIDTH +: CN_W];
    assign wake_valid[j] = stage_valid[DEPTH - 1][j] && !(|(last_spec & cn_port_mask));
    assign wake_lane[j]  = stage_bits[DEPTH - 1][j][DW-1];
    assign wake_preg[j]  = stage_bits[DEPTH - 1][j][RPW +: PRF_IDX_WIDTH];
  end

endmodule

`default_nettype wire
