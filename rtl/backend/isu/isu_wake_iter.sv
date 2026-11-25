// Ref: back-end/Isu.cpp  Isu::comb_calc_latency_next / comb_flush (div_wake_slots, fp_wake_slots)
`default_nettype none

module isu_wake_iter
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SLOTS = 2,
  parameter int NREQ  = 2,
  parameter int CW    = COUNT_W
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [NREQ-1:0]          req_valid,
  input  logic [PRF_IDX_WIDTH-1:0] req_preg [NREQ],
  input  logic [ROB_IDX_WIDTH-1:0] req_rob_idx [NREQ],
  input  logic [NREQ-1:0]          req_rob_flag,
  input  logic [CW-1:0]            req_countdown [NREQ],
  input  logic [NREQ-1:0]          req_lane,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  output logic [SLOTS-1:0]         wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [SLOTS],
  output logic [SLOTS-1:0]         wake_lane
);

  localparam int RPW = 1 + ROB_IDX_WIDTH;
  localparam int DW  = 1 + PRF_IDX_WIDTH + RPW + CW;

  logic [SLOTS-1:0] slot_free;
  logic [SLOTS-1:0] alloc_slot [NREQ];
  logic [DW-1:0]    req_bits [NREQ];
  logic [NREQ-1:0]  req_killed;

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    assign req_bits[r]   = {req_lane[r], req_preg[r], req_rob_flag[r], req_rob_idx[r], req_countdown[r]};
    assign req_killed[r] = flush_br && isu_rob_younger(req_rob_idx[r], req_rob_flag[r], flush_rob_idx, flush_rob_flag);
  end

  if (NREQ == 1) begin : g_alloc1
    logic [SLOTS-1:0] first_free;
    /* verilator lint_off UNUSEDSIGNAL */
    logic             any_free;
    /* verilator lint_on UNUSEDSIGNAL */
    ttg_first_set #(.N(SLOTS)) u_first (.req(slot_free), .onehot(first_free), .any(any_free));
    assign alloc_slot[0] = req_valid[0] ? first_free : '0;
  end else begin : g_allocn
    isu_alloc_chain #(.NREQ(NREQ), .NSLOT(SLOTS)) u_alloc (
      .clk(clk), .req(req_valid), .free(slot_free), .slot_onehot(alloc_slot));
  end

  for (genvar j = 0; j < SLOTS; j++) begin : g_slot
    logic                     valid_q, valid_d;
    logic                     lane_q, lane_d;
    logic [CW-1:0]            count_q, count_d;
    logic [PRF_IDX_WIDTH-1:0] preg_q, preg_d;
    logic [RPW-1:0]           rptr_q, rptr_d;
    logic [NREQ-1:0]          hit;
    logic [DW-1:0]            new_bits;
    logic                     counting;
    logic                     old_killed;

    for (genvar r = 0; r < NREQ; r++) begin : g_hit
      assign hit[r] = alloc_slot[r][j];
    end
    if (NREQ == 1) begin : g_new1
      assign new_bits = req_bits[0];
    end else begin : g_newn
      ttg_onehot_mux #(.N(NREQ), .W(DW)) u_new (.sel(hit), .data(req_bits), .out(new_bits));
    end

    assign counting     = valid_q && (count_q != '0);
    assign slot_free[j] = !counting;
    assign old_killed   = flush_br && isu_rob_younger(rptr_q[ROB_IDX_WIDTH-1:0], rptr_q[ROB_IDX_WIDTH],
                                                      flush_rob_idx, flush_rob_flag);

    always_comb begin
      if (NREQ == 1) begin
        valid_d = (req_valid[0] && !req_killed[0] && !flush_all && alloc_slot[0][j]) ||
                  (counting && !old_killed && !flush_all);
        lane_d  = slot_free[j] ? new_bits[DW-1] : lane_q;
        count_d = slot_free[j] ? new_bits[CW-1:0] : (count_q - CW'(1));
        preg_d  = slot_free[j] ? new_bits[(CW + RPW) +: PRF_IDX_WIDTH] : preg_q;
        rptr_d  = slot_free[j] ? new_bits[CW +: RPW] : rptr_q;
      end else begin
        valid_d = ((|(hit & ~req_killed)) || (counting && !old_killed)) && !flush_all;
        lane_d  = (|hit) ? new_bits[DW-1] : lane_q;
        count_d = (|hit) ? new_bits[CW-1:0] : (count_q - CW'(1));
        preg_d  = (|hit) ? new_bits[(CW + RPW) +: PRF_IDX_WIDTH] : preg_q;
        rptr_d  = (|hit) ? new_bits[CW +: RPW] : rptr_q;
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q <= 1'b0;
        lane_q  <= 1'b0;
        count_q <= '0;
        preg_q  <= '0;
        rptr_q  <= '0;
      end else begin
        valid_q <= valid_d;
        lane_q  <= lane_d;
        count_q <= count_d;
        preg_q  <= preg_d;
        rptr_q  <= rptr_d;
      end
    end

    assign wake_valid[j] = valid_q && (count_q == '0);
    assign wake_preg[j]  = preg_q;
    assign wake_lane[j]  = lane_q;
  end

endmodule

`default_nettype wire
