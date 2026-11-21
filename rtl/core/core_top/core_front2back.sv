// Ref: Front2Back.cpp  Front2Back::comb (no-taken cut with 2-taken discontinuity reset, 8/16 widening, stall hold)
`default_nettype none

module core_front2back import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        can_read,
  // front.out
  input  logic [FETCH_WIDTH-1:0] lane_valid,
  input  logic [31:0] instructions     [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] page_fault_inst,
  input  logic [FETCH_WIDTH-1:0] pf_inst_hi,
  input  logic [FETCH_WIDTH-1:0] predict_dir,
  input  logic [FETCH_WIDTH-1:0] is_rvc,
  input  logic [XLEN_BITS-1:0] pc      [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] alt_pred,
  input  logic [PCPN_W-1:0]       pcpn    [FETCH_WIDTH],
  input  logic [BLK_ID_W-1:0]     blk_id,
  input  logic                    is_pair,
  input  logic [3:0]              a_len,
  input  logic [XLEN_BITS-1:0] predict_next_fetch_address,
  input  logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind,
  // back.in (front part)
  output logic [BACKEND_FETCH_WIDTH-1:0] back_valid,
  output logic [31:0] back_inst        [BACKEND_FETCH_WIDTH],
  output logic [BACKEND_FETCH_WIDTH-1:0] back_page_fault,
  output logic [BACKEND_FETCH_WIDTH-1:0] back_pf_inst_hi,
  output logic [XLEN_BITS-1:0] back_pc [BACKEND_FETCH_WIDTH],
  output logic [BACKEND_FETCH_WIDTH-1:0] back_predict_dir,
  output logic [BACKEND_FETCH_WIDTH-1:0] back_is_rvc,
  output logic [BACKEND_FETCH_WIDTH-1:0] back_alt_pred,
  output logic [PCPN_W-1:0]       back_pcpn    [BACKEND_FETCH_WIDTH],
  output logic [BLK_ID_W-1:0]     back_blk_id,
  output logic                    back_is_pair,
  output logic [3:0]              back_a_len,
  output logic [XLEN_BITS-1:0] back_predict_next_fetch_address,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] back_slot_kind
);

  localparam logic [31:0] INST_NOP_WORD = 32'h00000013;

  // ---- cut after a predicted-taken lane, resetting on 2-taken PC discontinuity (Front2Back.cpp) ----
  logic [FETCH_WIDTH-1:0] cut_valid;

  always_comb begin
    logic no_taken, prev_v;
    no_taken = 1'b1;
    prev_v   = 1'b0;
    for (int j = 0; j < FETCH_WIDTH; j++) begin
      if ((j > 0) && !no_taken && prev_v && lane_valid[j] &&
          (pc[j] != pc[j - 1] + (is_rvc[j - 1] ? XLEN_BITS'(2) : XLEN_BITS'(4))) && predict_dir[j - 1])
        no_taken = 1'b1;
      prev_v       = no_taken && lane_valid[j];
      cut_valid[j] = prev_v;
      if (prev_v && predict_dir[j]) no_taken = 1'b0;
    end
  end

  // ---- front end group in the back-end format ----
  logic [BACKEND_FETCH_WIDTH-1:0] fe_valid;
  logic [31:0] fe_inst        [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] fe_page_fault;
  logic [BACKEND_FETCH_WIDTH-1:0] fe_pf_inst_hi;
  logic [XLEN_BITS-1:0] fe_pc [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] fe_predict_dir;
  logic [BACKEND_FETCH_WIDTH-1:0] fe_is_rvc;
  logic [BACKEND_FETCH_WIDTH-1:0] fe_alt_pred;
  logic [PCPN_W-1:0]     fe_pcpn    [BACKEND_FETCH_WIDTH];

  always_comb begin
    for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
      fe_valid[j]       = 1'b0;
      fe_inst[j]        = INST_NOP_WORD;
      fe_page_fault[j]  = 1'b0;
      fe_pf_inst_hi[j]  = 1'b0;
      fe_pc[j]          = '0;
      fe_predict_dir[j] = 1'b0;
      fe_is_rvc[j]      = 1'b0;
      fe_alt_pred[j]    = 1'b0;
      fe_pcpn[j]        = '0;
    end
    for (int j = 0; j < FETCH_WIDTH; j++) begin
      fe_valid[j]       = cut_valid[j];
      fe_inst[j]        = instructions[j];
      fe_page_fault[j]  = page_fault_inst[j];
      fe_pf_inst_hi[j]  = pf_inst_hi[j];
      fe_pc[j]          = pc[j];
      fe_predict_dir[j] = predict_dir[j];
      fe_is_rvc[j]      = is_rvc[j];
      fe_alt_pred[j]    = alt_pred[j];
      fe_pcpn[j]        = pcpn[j];
    end
  end

  // ---- hold register ----
  logic [BACKEND_FETCH_WIDTH-1:0] hold_valid_q;
  logic [31:0] hold_inst_q        [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] hold_page_fault_q;
  logic [BACKEND_FETCH_WIDTH-1:0] hold_pf_inst_hi_q;
  logic [XLEN_BITS-1:0] hold_pc_q [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] hold_predict_dir_q;
  logic [BACKEND_FETCH_WIDTH-1:0] hold_is_rvc_q;
  logic [BACKEND_FETCH_WIDTH-1:0] hold_alt_pred_q;
  logic [PCPN_W-1:0]     hold_pcpn_q    [BACKEND_FETCH_WIDTH];
  logic [BLK_ID_W-1:0]   hold_blk_id_q;
  logic                  hold_is_pair_q;
  logic [3:0]            hold_a_len_q;
  logic [XLEN_BITS-1:0]  hold_next_q;
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] hold_slot_kind_q;

  always_comb begin
    for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
      back_valid[j]       = can_read ? fe_valid[j]       : hold_valid_q[j];
      back_inst[j]        = can_read ? fe_inst[j]        : hold_inst_q[j];
      back_page_fault[j]  = can_read ? fe_page_fault[j]  : hold_page_fault_q[j];
      back_pf_inst_hi[j]  = can_read ? fe_pf_inst_hi[j]  : hold_pf_inst_hi_q[j];
      back_pc[j]          = can_read ? fe_pc[j]          : hold_pc_q[j];
      back_predict_dir[j] = can_read ? fe_predict_dir[j] : hold_predict_dir_q[j];
      back_is_rvc[j]      = can_read ? fe_is_rvc[j]      : hold_is_rvc_q[j];
      back_alt_pred[j]    = can_read ? fe_alt_pred[j]    : hold_alt_pred_q[j];
      back_pcpn[j]        = can_read ? fe_pcpn[j]        : hold_pcpn_q[j];
    end
    back_blk_id                     = can_read ? blk_id  : hold_blk_id_q;
    back_is_pair                    = can_read ? is_pair : hold_is_pair_q;
    back_a_len                      = can_read ? a_len   : hold_a_len_q;
    back_predict_next_fetch_address = can_read ? predict_next_fetch_address : hold_next_q;
    back_slot_kind                  = can_read ? slot_kind : hold_slot_kind_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
        hold_valid_q[j]       <= 1'b0;
        hold_inst_q[j]        <= INST_NOP_WORD;
        hold_page_fault_q[j]  <= 1'b0;
        hold_pf_inst_hi_q[j]  <= 1'b0;
        hold_pc_q[j]          <= '0;
        hold_predict_dir_q[j] <= 1'b0;
        hold_is_rvc_q[j]      <= 1'b0;
        hold_alt_pred_q[j]    <= 1'b0;
        hold_pcpn_q[j]        <= '0;
      end
      hold_blk_id_q    <= '0;
      hold_is_pair_q   <= 1'b0;
      hold_a_len_q     <= '0;
      hold_next_q      <= '0;
      hold_slot_kind_q <= '0;
    end else begin
      for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
        hold_valid_q[j]       <= back_valid[j];
        hold_inst_q[j]        <= back_inst[j];
        hold_page_fault_q[j]  <= back_page_fault[j];
        hold_pf_inst_hi_q[j]  <= back_pf_inst_hi[j];
        hold_pc_q[j]          <= back_pc[j];
        hold_predict_dir_q[j] <= back_predict_dir[j];
        hold_is_rvc_q[j]      <= back_is_rvc[j];
        hold_alt_pred_q[j]    <= back_alt_pred[j];
        hold_pcpn_q[j]        <= back_pcpn[j];
      end
      hold_blk_id_q    <= back_blk_id;
      hold_is_pair_q   <= back_is_pair;
      hold_a_len_q     <= back_a_len;
      hold_next_q      <= back_predict_next_fetch_address;
      hold_slot_kind_q <= back_slot_kind;
    end
  end

endmodule

`default_nettype wire
