// Ref: back-end/Isu.cpp  Isu::comb_calc_latency_next / comb_flush (div_wake_slots, fp_wake_slots)
`default_nettype none

// Countdown wake-up slots for iterative units (DIV, FP). A slot broadcasts its dest preg when its countdown reaches 0
// and is free again in the same cycle (a new issue can take it). Killed by branch mask / global flush;
// resolved-branch bits are cleared from the mask.
module isu_wake_iter
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SLOTS = 2,
  parameter int NREQ  = 2
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // allocation requests = uops granted this cycle that need a delayed wake-up
  input  logic [NREQ-1:0]          req_valid,
  input  logic [PRF_IDX_WIDTH-1:0] req_preg [NREQ],
  input  logic [BR_MASK_WIDTH-1:0] req_br_mask [NREQ],
  input  logic [COUNT_W-1:0]       req_countdown [NREQ],
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  output logic [SLOTS-1:0]         wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [SLOTS]
);

  localparam int DW = PRF_IDX_WIDTH + BR_MASK_WIDTH + COUNT_W;

  logic [SLOTS-1:0] slot_free;
  logic [SLOTS-1:0] alloc_slot [NREQ];
  logic [DW-1:0]    req_bits [NREQ];

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    assign req_bits[r] = {req_preg[r], req_br_mask[r], req_countdown[r]};
  end

  isu_alloc_chain #(.NREQ(NREQ), .NSLOT(SLOTS)) u_alloc (
    .clk(clk), .req(req_valid), .free(slot_free), .slot_onehot(alloc_slot));

  for (genvar j = 0; j < SLOTS; j++) begin : g_slot
    logic                     valid_q, valid_d;
    logic [COUNT_W-1:0]       count_q, count_d;
    logic [PRF_IDX_WIDTH-1:0] preg_q, preg_d;
    logic [BR_MASK_WIDTH-1:0] mask_q, mask_d;
    logic [NREQ-1:0]          hit;
    logic [DW-1:0]            new_bits;
    logic                     counting;      // still has cycles to go, keeps the slot
    logic                     killed;

    for (genvar r = 0; r < NREQ; r++) begin : g_hit
      assign hit[r] = alloc_slot[r][j];
    end
    ttg_onehot_mux #(.N(NREQ), .W(DW)) u_new (.sel(hit), .data(req_bits), .out(new_bits));

    assign counting = valid_q && (count_q != '0);
    assign slot_free[j] = !counting;

    // Ref: Isu::comb_calc_latency_next, Isu::comb_flush
    always_comb begin
      valid_d = (|hit) || counting;
      count_d = (|hit) ? new_bits[COUNT_W-1:0] : (count_q - COUNT_W'(1));
      preg_d  = (|hit) ? new_bits[DW-1 -: PRF_IDX_WIDTH] : preg_q;
      mask_d  = (|hit) ? new_bits[COUNT_W +: BR_MASK_WIDTH] : mask_q;
      killed  = flush_br && ((mask_d & flush_br_mask) != '0);    // mask before the clear below
      valid_d = valid_d && !flush_all && !killed;
      mask_d  = mask_d & ~clear_mask;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q <= 1'b0;
        count_q <= '0;
        preg_q  <= '0;
        mask_q  <= '0;
      end else begin
        valid_q <= valid_d;
        count_q <= count_d;
        preg_q  <= preg_d;
        mask_q  <= mask_d;
      end
    end

    assign wake_valid[j] = valid_q && (count_q == '0);
    assign wake_preg[j]  = preg_q;
  end

endmodule

`default_nettype wire
