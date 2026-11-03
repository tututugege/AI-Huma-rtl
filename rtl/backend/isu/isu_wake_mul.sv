// Ref: back-end/Isu.cpp  Isu::comb_calc_latency_next / comb_flush (mul_wake_pipe)
`default_nettype none

// Fixed-latency wake-up pipe for MUL: a granted MUL enters stage 0 and moves one stage per cycle;
// the last stage broadcasts its dest preg. Killed by branch mask / global flush, mask bits cleared on resolve.
module isu_wake_mul
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SLOTS = 2,
  parameter int DEPTH = MUL_DEPTH,
  parameter int NREQ  = 2
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [NREQ-1:0]          req_valid,
  input  logic [PRF_IDX_WIDTH-1:0] req_preg [NREQ],
  input  logic [BR_MASK_WIDTH-1:0] req_br_mask [NREQ],
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  output logic [SLOTS-1:0]         wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [SLOTS]
);

  localparam int DW = PRF_IDX_WIDTH + BR_MASK_WIDTH;

  logic [SLOTS-1:0] alloc_slot [NREQ];
  logic [DW-1:0]    req_bits [NREQ];
  logic [DW-1:0]    stage_bits  [DEPTH][SLOTS];      // {preg, br_mask} per stage / slot (registered)
  logic [SLOTS-1:0] stage_valid [DEPTH];

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    assign req_bits[r] = {req_preg[r], req_br_mask[r]};
  end

  // stage 0 starts empty each cycle, so the k-th request takes slot k
  isu_alloc_chain #(.NREQ(NREQ), .NSLOT(SLOTS)) u_alloc (
    .clk(clk), .req(req_valid), .free({SLOTS{1'b1}}), .slot_onehot(alloc_slot));

  for (genvar s = 0; s < DEPTH; s++) begin : g_stage
    for (genvar j = 0; j < SLOTS; j++) begin : g_slot
      logic                     valid_q, valid_d;
      logic [DW-1:0]            bits_q, bits_d;
      logic                     enter_valid;       // what arrives in this stage this cycle
      logic [DW-1:0]            enter_bits;
      logic                     killed;

      if (s == 0) begin : g_first
        logic [NREQ-1:0] hit;
        for (genvar r = 0; r < NREQ; r++) begin : g_hit
          assign hit[r] = alloc_slot[r][j];
        end
        ttg_onehot_mux #(.N(NREQ), .W(DW)) u_new (.sel(hit), .data(req_bits), .out(enter_bits));
        assign enter_valid = |hit;
      end else begin : g_shift
        assign enter_valid = stage_valid[s - 1][j];
        assign enter_bits  = stage_bits[s - 1][j];
      end

      // Ref: Isu::comb_flush
      always_comb begin
        killed  = flush_br && ((enter_bits[BR_MASK_WIDTH-1:0] & flush_br_mask) != '0);   // mask before the clear
        valid_d = enter_valid && !flush_all && !killed;
        bits_d  = {enter_bits[DW-1 -: PRF_IDX_WIDTH], enter_bits[BR_MASK_WIDTH-1:0] & ~clear_mask};
      end

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          valid_q <= 1'b0;
          bits_q  <= '0;
        end else begin
          valid_q <= valid_d;
          bits_q  <= bits_d;
        end
      end
      assign stage_valid[s][j] = valid_q;
      assign stage_bits[s][j]  = bits_q;
    end
  end

  for (genvar j = 0; j < SLOTS; j++) begin : g_out
    assign wake_valid[j] = stage_valid[DEPTH - 1][j];
    assign wake_preg[j]  = stage_bits[DEPTH - 1][j][DW-1 -: PRF_IDX_WIDTH];
  end

endmodule

`default_nettype wire
