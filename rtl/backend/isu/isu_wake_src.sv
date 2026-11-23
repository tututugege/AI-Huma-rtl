// Ref: back-end/Isu.cpp  Isu::comb_awake, Isu::comb_calc_latency_next, Isu::get_latency
`default_nettype none

// The 14 wake-up channels broadcast on iss_awake, in fixed positions:
//   LD: load write-back wake-ups from the PRF     MUL: MUL pipe end     DIV: DIV countdown slots
//   FAST: one per ALU-capable port, single-cycle uops granted this cycle
// MUL/DIV uops granted this cycle are put into their delayed wake-up structure (visible from the next cycle).
module isu_wake_src
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] prf_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] prf_wake_preg [LSU_LOAD_WB_WIDTH],
  input  logic                     exe_div_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] exe_div_wake_preg,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: ports that cannot start a delayed-wake op are not read
  input  logic [ISSUE_WIDTH-1:0]   cand_valid,    // pre-fp-gate grants (equal to grant_valid for single-cycle ALU ops)
  input  logic [ISSUE_WIDTH-1:0]   grant_valid,   // grants of every issue port
  input  isu_uop_t [ISSUE_WIDTH-1:0] grant_uop,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  output logic [WAKE_NUM-1:0]      wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [WAKE_NUM],
  // Per-ALU-lane registered EXU bypass wake-up (MUL on lanes 0,2; DIV on lanes 1,3) for wakeup-driven bypass masks
  output logic [ALU_NUM-1:0]       slow_exu_valid,
  output logic [$clog2(PRF_NUM)-1:0] slow_exu_preg [ALU_NUM],
  // Uncompacted FP wake-up slots (bypass u_compact when building isu's internal slow wake-up bitmaps)
  output logic [FP_REQ_UNITS*5-1:0] fp_raw_valid,
  output logic [PRF_IDX_WIDTH-1:0]  fp_raw_preg [FP_REQ_UNITS*5]
);

  // ---- load channels: straight from the PRF ----
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_ld
    assign wake_valid[LD_WAKE_BASE + k] = prf_wake_valid[k];
    assign wake_preg[LD_WAKE_BASE + k]  = prf_wake_preg[k];
  end

  // ---- delayed-wake requests: granted uops with a destination whose op class has latency > 1 ----
  logic [MUL_UNITS-1:0]     mul_req_valid;
  logic [PRF_IDX_WIDTH-1:0] mul_req_preg [MUL_UNITS];
  logic [BR_MASK_WIDTH-1:0] mul_req_mask [MUL_UNITS];

  // Only a port whose capability includes the class can be granted such a uop, so requests come from those ports only.
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    if (port_has(MASK_MUL, p)) begin : g_mul
      localparam int R = port_rank(MASK_MUL, p);
      assign mul_req_valid[R] = (MUL_DELAYED != 0) && grant_valid[p] && grant_uop[p].dest_en &&
                                (grant_uop[p].op == op_t'(UOP_MUL));
      assign mul_req_preg[R]  = grant_uop[p].dest_preg;
      assign mul_req_mask[R]  = grant_uop[p].br_mask;
    end
    // fast wake-up: single-cycle uop with a destination (ports that can issue ALU ops own a fast channel)
    if (port_has(MASK_ALU, p)) begin : g_fast
      localparam int R = port_rank(MASK_ALU, p);
      logic delayed_op;
      assign delayed_op = ((MUL_DELAYED != 0) && grant_uop[p].op == op_t'(UOP_MUL)) ||
                          (DIV_MAX_LATENCY > 1 && grant_uop[p].op == op_t'(UOP_DIV)) ||
                          (FP_EN && grant_uop[p].op == op_t'(UOP_I2F));   // integer -> FP: multi-cycle
      assign wake_valid[FAST_WAKE_BASE + R] = cand_valid[p] && grant_uop[p].dest_en && !delayed_op;
      assign wake_preg[FAST_WAKE_BASE + R]  = grant_uop[p].dest_preg;
    end
  end

  // ---- F/D: delayed wake-ups of the FP units (and of I2F on the integer ports), countdown slots ----
  if (FP_EN) begin : g_fp
    logic [FP_REQ_UNITS-1:0]  fp_req_valid;
    logic [PRF_IDX_WIDTH-1:0] fp_req_preg [FP_REQ_UNITS];
    logic [BR_MASK_WIDTH-1:0] fp_req_mask [FP_REQ_UNITS];
    logic [FP_COUNT_W-1:0]    fp_req_count [FP_REQ_UNITS];
    for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
      if (port_has(MASK_FPD, p)) begin : g_req
        localparam int R = port_rank(MASK_FPD, p);
        logic [FP_COUNT_W:0] lat;
        logic is_fp_op;
        assign lat       = fp_latency(grant_uop[p].op, grant_uop[p].func7);
        assign is_fp_op  = (grant_uop[p].op == op_t'(UOP_FMA)) || (grant_uop[p].op == op_t'(UOP_FMISC)) ||
                           (grant_uop[p].op == op_t'(UOP_FDIV)) || (grant_uop[p].op == op_t'(UOP_I2F));
        assign fp_req_valid[R] = grant_valid[p] && grant_uop[p].dest_en && is_fp_op;
        assign fp_req_preg[R]  = grant_uop[p].dest_preg;
        assign fp_req_mask[R]  = grant_uop[p].br_mask;
        assign fp_req_count[R] = FP_COUNT_W'(lat - (FP_COUNT_W+1)'(1));
      end
    end

    // Per-port private countdown slots (NREQ=1 each): eliminates cross-port 5-way isu_alloc_chain on the FP grant path.
    // Max in-flight per port: I2F=3, FMA/FMISC=4, FDIV(1)+FMISC(2)=3 -> 5 private slots/port cannot overflow.
    localparam int FP_PORT_SLOTS = 5;
    localparam int FP_TOT_SLOTS  = FP_REQ_UNITS * FP_PORT_SLOTS;
    logic [FP_TOT_SLOTS-1:0]      fp_slot_valid;
    logic [PRF_IDX_WIDTH-1:0]     fp_slot_preg [FP_TOT_SLOTS];
    for (genvar r = 0; r < FP_REQ_UNITS; r++) begin : g_fp_port
      logic [PRF_IDX_WIDTH-1:0] p_preg [1];
      logic [BR_MASK_WIDTH-1:0] p_mask [1];
      logic [FP_COUNT_W-1:0]    p_cnt  [1];
      logic [FP_PORT_SLOTS-1:0] p_wv;
      logic [PRF_IDX_WIDTH-1:0] p_wp [FP_PORT_SLOTS];
      /* verilator lint_off UNUSEDSIGNAL */   // waiver: FP slots do not use the 1-bit source-port tag
      logic [FP_PORT_SLOTS-1:0] p_wl;
      /* verilator lint_on UNUSEDSIGNAL */
      assign p_preg[0] = fp_req_preg[r];
      assign p_mask[0] = fp_req_mask[r];
      assign p_cnt[0]  = fp_req_count[r];
      isu_wake_iter #(.SLOTS(FP_PORT_SLOTS), .NREQ(1), .CW(FP_COUNT_W)) u_fp (
        .clk(clk), .rst_n(rst_n), .req_valid(fp_req_valid[r]), .req_preg(p_preg), .req_br_mask(p_mask),
        .req_countdown(p_cnt), .req_lane(1'b0),
        .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask), .clear_mask(clear_mask),
        .wake_valid(p_wv), .wake_preg(p_wp), .wake_lane(p_wl));
      for (genvar s = 0; s < FP_PORT_SLOTS; s++) begin : g_s
        assign fp_slot_valid[r * FP_PORT_SLOTS + s] = p_wv[s];
        assign fp_slot_preg[r * FP_PORT_SLOTS + s]  = p_wp[s];
      end
    end

    assign fp_raw_valid = fp_slot_valid;
    assign fp_raw_preg  = fp_slot_preg;

    logic [FPW_CH-1:0]        fpw_valid;
    logic [PRF_IDX_WIDTH-1:0] fpw_preg [FPW_CH];
    isu_wake_compact #(.N(FP_TOT_SLOTS), .M(FPW_CH)) u_compact (
      .clk(clk), .in_valid(fp_slot_valid), .in_preg(fp_slot_preg), .out_valid(fpw_valid), .out_preg(fpw_preg));
    for (genvar c = 0; c < FPW_CH; c++) begin : g_ch
      assign wake_valid[FP_WAKE_BASE + c] = fpw_valid[c];
      assign wake_preg[FP_WAKE_BASE + c]  = fpw_preg[c];
    end
  end else begin : g_nofp
    assign fp_raw_valid = '0;
    for (genvar s = 0; s < FP_REQ_UNITS * 5; s++) begin : g_z
      assign fp_raw_preg[s] = '0;
    end
  end

  // ---- delayed structures ----
  localparam int INT_W = $clog2(PRF_NUM);
  logic [MUL_UNITS-1:0]     mul_wake_valid, mul_wake_lane, mul_req_lane;
  logic [PRF_IDX_WIDTH-1:0] mul_wake_preg [MUL_UNITS];
  for (genvar r = 0; r < MUL_UNITS; r++) begin : g_mlane
    assign mul_req_lane[r] = 1'(r);
  end

  isu_wake_mul #(.SLOTS(MUL_UNITS), .NREQ(MUL_UNITS)) u_mul (
    .clk(clk), .rst_n(rst_n), .req_valid(mul_req_valid), .req_preg(mul_req_preg), .req_br_mask(mul_req_mask),
    .req_lane(mul_req_lane),
    .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask), .clear_mask(clear_mask),
    .wake_valid(mul_wake_valid), .wake_preg(mul_wake_preg), .wake_lane(mul_wake_lane));

  for (genvar k = 0; k < MUL_UNITS; k++) begin : g_mul_out
    assign wake_valid[MUL_WAKE_BASE + k] = mul_wake_valid[k];
    assign wake_preg[MUL_WAKE_BASE + k]  = mul_wake_preg[k];
  end
  // Single variable-latency DIV on Port 1: woken dynamically by EXU one cycle before completion
  assign wake_valid[DIV_WAKE_BASE] = exe_div_wake_valid;
  assign wake_preg[DIV_WAKE_BASE]  = exe_div_wake_preg;

  // Map MUL (ports 0, 2) and DIV (port 1) delayed wake-ups onto their ALU write-back lanes (0..5)
  always_comb begin
    slow_exu_valid = '0;
    for (int l = 0; l < ALU_NUM; l++) slow_exu_preg[l] = '0;
    for (int k = 0; k < MUL_UNITS; k++) if (mul_wake_valid[k]) begin
      if (!mul_wake_lane[k]) begin
        slow_exu_valid[0] = 1'b1;
        slow_exu_preg[0]  = mul_wake_preg[k][INT_W-1:0];
      end else begin
        slow_exu_valid[2] = 1'b1;
        slow_exu_preg[2]  = mul_wake_preg[k][INT_W-1:0];
      end
    end
    if (exe_div_wake_valid) begin
      slow_exu_valid[1] = 1'b1;
      slow_exu_preg[1]  = exe_div_wake_preg[INT_W-1:0];
    end
  end

endmodule

`default_nettype wire
