// Ref: back-end/Isu.cpp  Isu::comb_awake, Isu::comb_calc_latency_next, Isu::get_latency
`default_nettype none

// The 15 wake-up channels broadcast on iss_awake, in fixed positions:
//   LD: load write-back wake-ups from the PRF     MUL: MUL pipe end     DIV: DIV countdown slots
//   FP: FP countdown slots     FAST: one per ALU-capable port, single-cycle uops granted this cycle
// MUL/DIV/FP uops granted this cycle are put into their delayed wake-up structure (visible from the next cycle).
module isu_wake_src
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] prf_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] prf_wake_preg [LSU_LOAD_WB_WIDTH],
  input  logic [WAKE_PORTS-1:0]    grant_valid,   // grants of issue ports 0..WAKE_PORTS-1
  input  isu_uop_t [WAKE_PORTS-1:0] grant_uop,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  output logic [WAKE_NUM-1:0]      wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [WAKE_NUM]
);

  // ---- load channels: straight from the PRF ----
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_ld
    assign wake_valid[LD_WAKE_BASE + k] = prf_wake_valid[k];
    assign wake_preg[LD_WAKE_BASE + k]  = prf_wake_preg[k];
  end

  // ---- delayed-wake requests: granted uops with a destination whose op class has latency > 1 ----
  logic [MUL_UNITS-1:0]     mul_req_valid;
  logic [DIV_UNITS-1:0]     div_req_valid;
  logic [FP_UNITS-1:0]      fp_req_valid;
  logic [PRF_IDX_WIDTH-1:0] mul_req_preg [MUL_UNITS];
  logic [PRF_IDX_WIDTH-1:0] div_req_preg [DIV_UNITS];
  logic [PRF_IDX_WIDTH-1:0] fp_req_preg [FP_UNITS];
  logic [BR_MASK_WIDTH-1:0] mul_req_mask [MUL_UNITS];
  logic [BR_MASK_WIDTH-1:0] div_req_mask [DIV_UNITS];
  logic [BR_MASK_WIDTH-1:0] fp_req_mask [FP_UNITS];
  logic [COUNT_W-1:0]       div_req_count [DIV_UNITS];
  logic [COUNT_W-1:0]       fp_req_count [FP_UNITS];

  // Only a port whose capability includes the class can be granted such a uop, so requests come from those ports only.
  for (genvar p = 0; p < WAKE_PORTS; p++) begin : g_port
    if (port_has(MASK_MUL, p)) begin : g_mul
      localparam int R = port_rank(MASK_MUL, p);
      assign mul_req_valid[R] = (MUL_DELAYED != 0) && grant_valid[p] && grant_uop[p].dest_en &&
                                (grant_uop[p].op == op_t'(UOP_MUL));
      assign mul_req_preg[R]  = grant_uop[p].dest_preg;
      assign mul_req_mask[R]  = grant_uop[p].br_mask;
    end
    if (port_has(MASK_DIV, p)) begin : g_div
      localparam int R = port_rank(MASK_DIV, p);
      assign div_req_valid[R] = grant_valid[p] && grant_uop[p].dest_en && (grant_uop[p].op == op_t'(UOP_DIV));
      assign div_req_preg[R]  = grant_uop[p].dest_preg;
      assign div_req_mask[R]  = grant_uop[p].br_mask;
      // rv64 divw / divuw / remw / remuw take half the iterations (Isu::get_latency: div_latency(is_word))
      assign div_req_count[R] = (XLEN_BITS == 64 && grant_uop[p].is_word) ? COUNT_W'(DIV_MAX_LATENCY / 2 - 1)
                                                                          : COUNT_W'(DIV_MAX_LATENCY - 1);
    end
    if (port_has(MASK_FP, p)) begin : g_fp
      localparam int R = port_rank(MASK_FP, p);
      assign fp_req_valid[R] = grant_valid[p] && grant_uop[p].dest_en && (grant_uop[p].op == op_t'(UOP_FP));
      assign fp_req_preg[R]  = grant_uop[p].dest_preg;
      assign fp_req_mask[R]  = grant_uop[p].br_mask;
      assign fp_req_count[R] = fp_countdown(grant_uop[p].func7);
    end
    // fast wake-up: single-cycle uop with a destination (ports that can issue ALU ops own a fast channel)
    if (port_has(MASK_ALU, p)) begin : g_fast
      localparam int R = port_rank(MASK_ALU, p);
      logic delayed_op;
      assign delayed_op = ((MUL_DELAYED != 0) && grant_uop[p].op == op_t'(UOP_MUL)) ||
                          (DIV_MAX_LATENCY > 1 && grant_uop[p].op == op_t'(UOP_DIV)) ||
                          (grant_uop[p].op == op_t'(UOP_FP));
      assign wake_valid[FAST_WAKE_BASE + R] = grant_valid[p] && grant_uop[p].dest_en && !delayed_op;
      assign wake_preg[FAST_WAKE_BASE + R]  = grant_uop[p].dest_preg;
    end
  end

  // ---- delayed structures ----
  logic [MUL_UNITS-1:0]     mul_wake_valid;
  logic [DIV_UNITS-1:0]     div_wake_valid;
  logic [FP_UNITS-1:0]      fp_wake_valid;
  logic [PRF_IDX_WIDTH-1:0] mul_wake_preg [MUL_UNITS];
  logic [PRF_IDX_WIDTH-1:0] div_wake_preg [DIV_UNITS];
  logic [PRF_IDX_WIDTH-1:0] fp_wake_preg [FP_UNITS];

  isu_wake_mul #(.SLOTS(MUL_UNITS), .NREQ(MUL_UNITS)) u_mul (
    .clk(clk), .rst_n(rst_n), .req_valid(mul_req_valid), .req_preg(mul_req_preg), .req_br_mask(mul_req_mask),
    .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask), .clear_mask(clear_mask),
    .wake_valid(mul_wake_valid), .wake_preg(mul_wake_preg));

  isu_wake_iter #(.SLOTS(DIV_UNITS), .NREQ(DIV_UNITS)) u_div (
    .clk(clk), .rst_n(rst_n), .req_valid(div_req_valid), .req_preg(div_req_preg), .req_br_mask(div_req_mask),
    .req_countdown(div_req_count),
    .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask), .clear_mask(clear_mask),
    .wake_valid(div_wake_valid), .wake_preg(div_wake_preg));

  isu_wake_iter #(.SLOTS(FP_UNITS), .NREQ(FP_UNITS)) u_fp (
    .clk(clk), .rst_n(rst_n), .req_valid(fp_req_valid), .req_preg(fp_req_preg), .req_br_mask(fp_req_mask),
    .req_countdown(fp_req_count),
    .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask), .clear_mask(clear_mask),
    .wake_valid(fp_wake_valid), .wake_preg(fp_wake_preg));

  for (genvar k = 0; k < MUL_UNITS; k++) begin : g_mul_out
    assign wake_valid[MUL_WAKE_BASE + k] = mul_wake_valid[k];
    assign wake_preg[MUL_WAKE_BASE + k]  = mul_wake_preg[k];
  end
  for (genvar k = 0; k < DIV_UNITS; k++) begin : g_div_out
    assign wake_valid[DIV_WAKE_BASE + k] = div_wake_valid[k];
    assign wake_preg[DIV_WAKE_BASE + k]  = div_wake_preg[k];
  end
  for (genvar k = 0; k < FP_UNITS; k++) begin : g_fp_out
    assign wake_valid[FP_WAKE_BASE + k] = fp_wake_valid[k];
    assign wake_preg[FP_WAKE_BASE + k]  = fp_wake_preg[k];
  end

endmodule

`default_nettype wire
