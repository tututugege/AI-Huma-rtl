// Ref: rv_simu_mmu_v2.cpp  SimCpu::front_comb_before_back (front.out -> back.in), front2back_hold_comb / _seq
`default_nettype none

// Front end -> back end glue of SimCpu:
//   * can_read = front end may deliver this cycle (back end did not stall last cycle, or a redirect is pending);
//   * back.in.valid[j] = FIFO_valid & inst_valid[j] & no taken-predicted lane before j (the group is cut after the
//     first predicted-taken instruction), widened from the 8 front-end lanes to the 16 back-end lanes (lanes 8..15
//     are invalid NOPs);
//   * hold register: when the back end stalls, the group is kept (minus the lanes the back end already accepted) and
//     is presented again next cycle instead of the front end's output.
// The hold register is only ever read in the cycle after a stall without redirect, which is exactly when the C++
// stores a non-empty hold, so it is written every cycle (no clear needed).  The C++ also clears the lanes the back end
// accepted (pre2front.fire); the back end accepts all-or-nothing (PreIduQueue::comb_accept_front: fire = valid when
// ready, and ready = 0 means no lane fires), so a held group is always the complete group and `fire` is not needed.
module core_front2back import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        can_read,
  // front.out
  input  logic        lane_valid       [FETCH_WIDTH],
  input  logic [31:0] instructions     [FETCH_WIDTH],
  input  logic        page_fault_inst  [FETCH_WIDTH],
  input  logic        predict_dir      [FETCH_WIDTH],
  input  logic [31:0] pc               [FETCH_WIDTH],
  input  logic        alt_pred         [FETCH_WIDTH],
  input  logic [PCPN_W-1:0]       altpcpn [FETCH_WIDTH],
  input  logic [PCPN_W-1:0]       pcpn    [FETCH_WIDTH],
  input  logic [TAGE_IDX_W-1:0]   tage_idx [FETCH_WIDTH][TN_MAX],
  input  logic [TAGE_TAG_W-1:0]   tage_tag [FETCH_WIDTH][TN_MAX],
  input  logic [31:0] predict_next_fetch_address,
  // back.in (front part)
  output logic        back_valid       [BACKEND_FETCH_WIDTH],
  output logic [31:0] back_inst        [BACKEND_FETCH_WIDTH],
  output logic        back_page_fault  [BACKEND_FETCH_WIDTH],
  output logic [31:0] back_pc          [BACKEND_FETCH_WIDTH],
  output logic        back_predict_dir [BACKEND_FETCH_WIDTH],
  output logic        back_alt_pred    [BACKEND_FETCH_WIDTH],
  output logic [PCPN_W-1:0]       back_altpcpn [BACKEND_FETCH_WIDTH],
  output logic [PCPN_W-1:0]       back_pcpn    [BACKEND_FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0]   back_tage_idx [BACKEND_FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0]   back_tage_tag [BACKEND_FETCH_WIDTH][TN_MAX],
  output logic [31:0] back_predict_next_fetch_address
);

  localparam logic [31:0] INST_NOP_WORD = 32'h00000013;

  // ---- cut after the first predicted-taken valid lane ----
  logic [FETCH_WIDTH-1:0] taken_lane;      // lane valid and predicted taken (before the cut)
  logic [FETCH_WIDTH-1:0] cut_before;      // a taken lane exists below this one
  logic                   cut_valid [FETCH_WIDTH];

  always_comb begin
    for (int j = 0; j < FETCH_WIDTH; j++) begin
      taken_lane[j] = lane_valid[j] && predict_dir[j];
    end
    for (int j = 0; j < FETCH_WIDTH; j++) begin
      cut_before[j] = |(taken_lane & ((FETCH_WIDTH'(1) << j) - FETCH_WIDTH'(1)));
      cut_valid[j]  = lane_valid[j] && !cut_before[j];
    end
  end

  // ---- front end group in the 16-lane back-end format ----
  logic        fe_valid       [BACKEND_FETCH_WIDTH];
  logic [31:0] fe_inst        [BACKEND_FETCH_WIDTH];
  logic        fe_page_fault  [BACKEND_FETCH_WIDTH];
  logic [31:0] fe_pc          [BACKEND_FETCH_WIDTH];
  logic        fe_predict_dir [BACKEND_FETCH_WIDTH];
  logic        fe_alt_pred    [BACKEND_FETCH_WIDTH];
  logic [PCPN_W-1:0]     fe_altpcpn [BACKEND_FETCH_WIDTH];
  logic [PCPN_W-1:0]     fe_pcpn    [BACKEND_FETCH_WIDTH];
  logic [TAGE_IDX_W-1:0] fe_tage_idx [BACKEND_FETCH_WIDTH][TN_MAX];
  logic [TAGE_TAG_W-1:0] fe_tage_tag [BACKEND_FETCH_WIDTH][TN_MAX];

  always_comb begin
    for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
      fe_valid[j]       = 1'b0;
      fe_inst[j]        = INST_NOP_WORD;
      fe_page_fault[j]  = 1'b0;
      fe_pc[j]          = 32'd0;
      fe_predict_dir[j] = 1'b0;
      fe_alt_pred[j]    = 1'b0;
      fe_altpcpn[j]     = '0;
      fe_pcpn[j]        = '0;
      fe_tage_idx[j]    = '{default: '0};
      fe_tage_tag[j]    = '{default: '0};
    end
    for (int j = 0; j < FETCH_WIDTH; j++) begin
      fe_valid[j]       = cut_valid[j];
      fe_inst[j]        = instructions[j];
      fe_page_fault[j]  = page_fault_inst[j];
      fe_pc[j]          = pc[j];
      fe_predict_dir[j] = predict_dir[j];
      fe_alt_pred[j]    = alt_pred[j];
      fe_altpcpn[j]     = altpcpn[j];
      fe_pcpn[j]        = pcpn[j];
      fe_tage_idx[j]    = tage_idx[j];
      fe_tage_tag[j]    = tage_tag[j];
    end
  end

  // ---- hold register: the group as the back end saw it, minus the lanes it accepted ----
  logic        hold_valid_q       [BACKEND_FETCH_WIDTH];
  logic [31:0] hold_inst_q        [BACKEND_FETCH_WIDTH];
  logic        hold_page_fault_q  [BACKEND_FETCH_WIDTH];
  logic [31:0] hold_pc_q          [BACKEND_FETCH_WIDTH];
  logic        hold_predict_dir_q [BACKEND_FETCH_WIDTH];
  logic        hold_alt_pred_q    [BACKEND_FETCH_WIDTH];
  logic [PCPN_W-1:0]     hold_altpcpn_q [BACKEND_FETCH_WIDTH];
  logic [PCPN_W-1:0]     hold_pcpn_q    [BACKEND_FETCH_WIDTH];
  logic [TAGE_IDX_W-1:0] hold_tage_idx_q [BACKEND_FETCH_WIDTH][TN_MAX];
  logic [TAGE_TAG_W-1:0] hold_tage_tag_q [BACKEND_FETCH_WIDTH][TN_MAX];
  logic [31:0]           hold_next_q;

  always_comb begin
    for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
      back_valid[j]       = can_read ? fe_valid[j]       : hold_valid_q[j];
      back_inst[j]        = can_read ? fe_inst[j]        : hold_inst_q[j];
      back_page_fault[j]  = can_read ? fe_page_fault[j]  : hold_page_fault_q[j];
      back_pc[j]          = can_read ? fe_pc[j]          : hold_pc_q[j];
      back_predict_dir[j] = can_read ? fe_predict_dir[j] : hold_predict_dir_q[j];
      back_alt_pred[j]    = can_read ? fe_alt_pred[j]    : hold_alt_pred_q[j];
      back_altpcpn[j]     = can_read ? fe_altpcpn[j]     : hold_altpcpn_q[j];
      back_pcpn[j]        = can_read ? fe_pcpn[j]        : hold_pcpn_q[j];
      back_tage_idx[j]    = can_read ? fe_tage_idx[j]    : hold_tage_idx_q[j];
      back_tage_tag[j]    = can_read ? fe_tage_tag[j]    : hold_tage_tag_q[j];
    end
    back_predict_next_fetch_address = can_read ? predict_next_fetch_address : hold_next_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
        hold_valid_q[j]       <= 1'b0;
        hold_inst_q[j]        <= INST_NOP_WORD;
        hold_page_fault_q[j]  <= 1'b0;
        hold_pc_q[j]          <= 32'd0;
        hold_predict_dir_q[j] <= 1'b0;
        hold_alt_pred_q[j]    <= 1'b0;
        hold_altpcpn_q[j]     <= '0;
        hold_pcpn_q[j]        <= '0;
        hold_tage_idx_q[j]    <= '{default: '0};
        hold_tage_tag_q[j]    <= '{default: '0};
      end
      hold_next_q <= 32'd0;
    end else begin
      for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
        hold_valid_q[j]       <= back_valid[j];
        hold_inst_q[j]        <= back_inst[j];
        hold_page_fault_q[j]  <= back_page_fault[j];
        hold_pc_q[j]          <= back_pc[j];
        hold_predict_dir_q[j] <= back_predict_dir[j];
        hold_alt_pred_q[j]    <= back_alt_pred[j];
        hold_altpcpn_q[j]     <= back_altpcpn[j];
        hold_pcpn_q[j]        <= back_pcpn[j];
        hold_tage_idx_q[j]    <= back_tage_idx[j];
        hold_tage_tag_q[j]    <= back_tage_tag[j];
      end
      hold_next_q <= back_predict_next_fetch_address;
    end
  end

endmodule

`default_nettype wire
