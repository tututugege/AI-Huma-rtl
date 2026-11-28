// Ref: back-end/Isu.cpp  Isu::comb_awake, Isu::comb_calc_latency_next, Isu::get_latency
`default_nettype none

// The 21 wake-up channels broadcast on iss_awake (WAKE_NUM = MAX_WAKEUP_PORTS), in fixed positions:
//   LD (4): load write-back wake-ups from the PRF     MUL (2): MUL pipe end     DIV (1): the EXU's DIV early wake-up
//   FAST (6): one per ALU-capable port, single-cycle uops granted this cycle
//   FPW (FPW_CH = 8): delayed wake-ups of FMA / FMISC / FDIV / I2F (per-port countdown slots, compacted)
// MUL / FP uops granted this cycle are put into their delayed wake-up structure (visible from the next cycle).
module isu_wake_src
  import ttg_cfg_pkg::*;
  import isu_pkg::*, ttg_util_pkg::ttg_rob_younger;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] prf_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] prf_wake_preg [LSU_LOAD_WB_WIDTH],
  input  logic                         exe_div_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]     exe_div_wake_preg,
  input  logic [LSU_LDU_COUNT-1:0]     cn_port_mask,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: ports that cannot start a delayed-wake op are not read
  input  logic [ISSUE_WIDTH-1:0]       cand_valid,    // pre-fp-gate grants (equal to grant_valid for single-cycle ALU ops)
  input  logic [ISSUE_WIDTH-1:0]       grant_valid,   // grants of every issue port
  input  isu_uop_t [ISSUE_WIDTH-1:0]   grant_uop,
  input  logic [LSU_LDU_COUNT-1:0]     grant_spec_mask [ISSUE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic                         flush_all,
  input  logic                         flush_br,
  input  logic [ROB_IDX_WIDTH-1:0]     flush_rob_idx,
  input  logic                         flush_rob_flag,
  output logic [WAKE_NUM-1:0]          wake_valid,
  output logic [PRF_IDX_WIDTH-1:0]     wake_preg [WAKE_NUM],
  output logic [ALU_NUM-1:0]           fast_cancel_raw,
  output logic [ALU_NUM-1:0]           fast_cancel_valid,
  output logic [PRF_IDX_WIDTH-1:0]     fast_cancel_preg [ALU_NUM],
  // Per-ALU-lane registered EXU bypass wake-up (MUL on lanes 0,2) for wakeup-driven bypass masks
  output logic [ALU_NUM-1:0]           slow_exu_valid,
  output logic [$clog2(PRF_NUM)-1:0]   slow_exu_preg [ALU_NUM],
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
  logic [ROB_IDX_WIDTH-1:0] mul_req_rob_idx [MUL_UNITS];
  logic [MUL_UNITS-1:0]     mul_req_rob_flag;
  logic [LSU_LDU_COUNT-1:0] mul_req_spec_mask [MUL_UNITS];

  logic [ALU_NUM-1:0]       fast_spec_v_q, fast_spec_v_d;
  logic [LSU_LDU_COUNT-1:0] fast_spec_mask_q [ALU_NUM], fast_spec_mask_d [ALU_NUM];
  logic [PRF_IDX_WIDTH-1:0] fast_spec_preg_q [ALU_NUM], fast_spec_preg_d [ALU_NUM];
  logic [ROB_IDX_WIDTH-1:0] fast_spec_ridx_q [ALU_NUM], fast_spec_ridx_d [ALU_NUM];
  logic [ALU_NUM-1:0]       fast_spec_rflag_q, fast_spec_rflag_d;

  always_comb begin
    for (int a = 0; a < ALU_NUM; a++) begin
      fast_cancel_raw[a]   = fast_spec_v_q[a] && (|(fast_spec_mask_q[a] & cn_port_mask));
      fast_cancel_valid[a] = fast_cancel_raw[a] && !flush_all &&
                             !(flush_br && ttg_rob_younger(fast_spec_ridx_q[a], fast_spec_rflag_q[a],
                                                           flush_rob_idx, flush_rob_flag));
      fast_cancel_preg[a]  = fast_spec_preg_q[a];
    end
  end

  // Only a port whose capability includes the class can be granted such a uop, so requests come from those ports only.
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    if (port_has(MASK_MUL, p)) begin : g_mul
      localparam int R = port_rank(MASK_MUL, p);
      assign mul_req_valid[R]     = (MUL_DELAYED != 0) && grant_valid[p] && grant_uop[p].dest_en &&
                                    (grant_uop[p].op == op_t'(dis_pkg::UOP_MUL));
      assign mul_req_preg[R]      = grant_uop[p].dest_preg;
      assign mul_req_rob_idx[R]   = grant_uop[p].rob_idx;
      assign mul_req_rob_flag[R]  = grant_uop[p].rob_flag;
      assign mul_req_spec_mask[R] = grant_spec_mask[p];
    end
    // fast wake-up: single-cycle uop with a destination (ports that can issue ALU ops own a fast channel)
    if (port_has(MASK_ALU, p)) begin : g_fast
      localparam int R = port_rank(MASK_ALU, p);
      logic delayed_op;
      assign delayed_op = ((MUL_DELAYED != 0) && grant_uop[p].op == op_t'(dis_pkg::UOP_MUL)) ||
                          (DIV_MAX_LATENCY > 1 && grant_uop[p].op == op_t'(dis_pkg::UOP_DIV)) ||
                          (grant_uop[p].op == op_t'(dis_pkg::UOP_I2F));   // integer -> FP: multi-cycle
      assign wake_valid[FAST_WAKE_BASE + R] = cand_valid[p] && grant_uop[p].dest_en && !delayed_op;
      assign wake_preg[FAST_WAKE_BASE + R]  = grant_uop[p].dest_preg;
      assign fast_spec_v_d[R]     = !flush_all && grant_valid[p] && grant_uop[p].dest_en &&
                                    !delayed_op && (|grant_spec_mask[p]);
      assign fast_spec_mask_d[R]  = grant_spec_mask[p];
      assign fast_spec_preg_d[R]  = grant_uop[p].dest_preg;
      assign fast_spec_ridx_d[R]  = grant_uop[p].rob_idx;
      assign fast_spec_rflag_d[R] = grant_uop[p].rob_flag;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fast_spec_v_q     <= '0;
      fast_spec_rflag_q <= '0;
      for (int a = 0; a < ALU_NUM; a++) begin
        fast_spec_mask_q[a] <= '0;
        fast_spec_preg_q[a] <= '0;
        fast_spec_ridx_q[a] <= '0;
      end
    end else begin
      fast_spec_v_q     <= fast_spec_v_d;
      fast_spec_rflag_q <= fast_spec_rflag_d;
      for (int a = 0; a < ALU_NUM; a++) begin
        fast_spec_mask_q[a] <= fast_spec_mask_d[a];
        fast_spec_preg_q[a] <= fast_spec_preg_d[a];
        fast_spec_ridx_q[a] <= fast_spec_ridx_d[a];
      end
    end
  end

  // ---- F/D: delayed wake-ups of the FP units (and of I2F on the integer ports), countdown slots ----
  logic [FP_REQ_UNITS-1:0]  fp_req_valid;
  logic [PRF_IDX_WIDTH-1:0] fp_req_preg [FP_REQ_UNITS];
  logic [ROB_IDX_WIDTH-1:0] fp_req_rob_idx [FP_REQ_UNITS];
  logic [FP_REQ_UNITS-1:0]  fp_req_rob_flag;
  logic [FP_COUNT_W-1:0]    fp_req_count [FP_REQ_UNITS];
  logic [LSU_LDU_COUNT-1:0] fp_req_spec_mask [FP_REQ_UNITS];
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_fp_port_req
    if (port_has(MASK_FPD, p)) begin : g_req
      localparam int R = port_rank(MASK_FPD, p);
      logic [FP_COUNT_W:0] lat;
      logic is_fp_op;
      assign lat       = fp_latency(grant_uop[p].op, grant_uop[p].func7);
      assign is_fp_op  = (grant_uop[p].op == op_t'(dis_pkg::UOP_FMA)) ||
                         (grant_uop[p].op == op_t'(dis_pkg::UOP_FMISC)) ||
                         (grant_uop[p].op == op_t'(dis_pkg::UOP_FDIV)) ||
                         (grant_uop[p].op == op_t'(dis_pkg::UOP_I2F));
      assign fp_req_valid[R]     = grant_valid[p] && grant_uop[p].dest_en && is_fp_op;
      assign fp_req_preg[R]      = grant_uop[p].dest_preg;
      assign fp_req_rob_idx[R]   = grant_uop[p].rob_idx;
      assign fp_req_rob_flag[R]  = grant_uop[p].rob_flag;
      assign fp_req_count[R]     = FP_COUNT_W'(lat - (FP_COUNT_W+1)'(1));
      assign fp_req_spec_mask[R] = grant_spec_mask[p];
    end
  end

  // Per-port private countdown slots (one request per cycle each): no cross-port 5-way allocation on the FP grant path.
  // Max in-flight per port: I2F=3, FMA/FMISC=4, FDIV(1)+FMISC(2)=3 -> 5 private slots/port cannot overflow.
  localparam int FP_PORT_SLOTS = 5;
  localparam int FP_TOT_SLOTS  = FP_REQ_UNITS * FP_PORT_SLOTS;
  logic [FP_TOT_SLOTS-1:0]      fp_slot_valid;
  logic [PRF_IDX_WIDTH-1:0]     fp_slot_preg [FP_TOT_SLOTS];
  for (genvar r = 0; r < FP_REQ_UNITS; r++) begin : g_fp_port
    logic [FP_PORT_SLOTS-1:0] p_wv;
    logic [PRF_IDX_WIDTH-1:0] p_wp [FP_PORT_SLOTS];
    isu_wake_iter #(.SLOTS(FP_PORT_SLOTS), .CW(FP_COUNT_W)) u_fp (
      .clk(clk), .rst_n(rst_n), .req_valid(fp_req_valid[r]), .req_preg(fp_req_preg[r]),
      .req_rob_idx(fp_req_rob_idx[r]), .req_rob_flag(fp_req_rob_flag[r]),
      .req_countdown(fp_req_count[r]), .req_spec_mask(fp_req_spec_mask[r]), .cn_port_mask(cn_port_mask),
      .flush_all(flush_all), .flush_br(flush_br), .flush_rob_idx(flush_rob_idx), .flush_rob_flag(flush_rob_flag),
      .wake_valid(p_wv), .wake_preg(p_wp));
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

  // ---- delayed structures ----
  localparam int INT_W = $clog2(PRF_NUM);
  logic [MUL_UNITS-1:0]     mul_wake_valid, mul_wake_lane, mul_req_lane;
  logic [PRF_IDX_WIDTH-1:0] mul_wake_preg [MUL_UNITS];
  for (genvar r = 0; r < MUL_UNITS; r++) begin : g_mlane
    assign mul_req_lane[r] = 1'(r);
  end

  isu_wake_mul #(.SLOTS(MUL_UNITS), .NREQ(MUL_UNITS)) u_mul (
    .clk(clk), .rst_n(rst_n), .req_valid(mul_req_valid), .req_preg(mul_req_preg),
    .req_rob_idx(mul_req_rob_idx), .req_rob_flag(mul_req_rob_flag),
    .req_lane(mul_req_lane), .req_spec_mask(mul_req_spec_mask), .cn_port_mask(cn_port_mask),
    .flush_all(flush_all), .flush_br(flush_br), .flush_rob_idx(flush_rob_idx), .flush_rob_flag(flush_rob_flag),
    .wake_valid(mul_wake_valid), .wake_preg(mul_wake_preg), .wake_lane(mul_wake_lane));

  for (genvar k = 0; k < MUL_UNITS; k++) begin : g_mul_out
    assign wake_valid[MUL_WAKE_BASE + k] = mul_wake_valid[k];
    assign wake_preg[MUL_WAKE_BASE + k]  = mul_wake_preg[k];
  end
  // Single variable-latency DIV on Port 1: woken dynamically by EXU one cycle before completion
  assign wake_valid[DIV_WAKE_BASE] = exe_div_wake_valid;
  assign wake_preg[DIV_WAKE_BASE]  = exe_div_wake_preg;

  // Map MUL (ports 0, 2) delayed wake-ups onto ALU write-back lanes; DIV reads wb_result_q in RR (no slow EXU bypass)
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
  end

endmodule

`default_nettype wire
