// Ref: back-end/Rob.cpp  class Rob  (entry[ROB_BANK_NUM][ROB_LINE_NUM] and the deq_ptr line read)
`default_nettype none

module rob_store
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       flush,
  input  logic [ROB_LINE_NUM-1:0]    enq_line_onehot,     // line written by this cycle's enqueue
  input  logic [ROB_LINE_NUM-1:0]    deq_line_onehot,     // head line
  input  logic [ROB_BANK_NUM-1:0]    fire_bank,           // dis_fire & ready, per bank
  input  rob_entry_t                 fire_uop [ROB_BANK_NUM],
  input  logic [ROB_BANK_NUM-1:0]    commit_clr_bank,     // banks of the head line retired this cycle
  input  logic [ROB_LINE_NUM-1:0]    branch_clr [ROB_BANK_NUM],
  input  logic [ROB_LINE_NUM-1:0]    mark_last  [ROB_BANK_NUM],
  input  rob_event_t                 wb_ev [ISSUE_WIDTH],
  output logic [ROB_BANK_NUM-1:0]    head_valid,
  output rob_entry_t                 head_uop [ROB_BANK_NUM]
);

  localparam int SLOT_W = 1 + ROB_ENTRY_W;

  logic       slot_valid [ROB_BANK_NUM][ROB_LINE_NUM];
  rob_entry_t slot_uop   [ROB_BANK_NUM][ROB_LINE_NUM];
  logic [SLOT_W-1:0] slot_bits [ROB_BANK_NUM][ROB_LINE_NUM];
  logic [SLOT_W-1:0] head_bits [ROB_BANK_NUM];

  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_bank
    for (genvar l = 0; l < ROB_LINE_NUM; l++) begin : g_line
      rob_entry #(
        .ENTRY_IDX(l * ROB_BANK_NUM + b)
      ) u_entry (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (flush),
        .fire_we    (fire_bank[b] & enq_line_onehot[l]),
        .fire_uop   (fire_uop[b]),
        .commit_clr (commit_clr_bank[b] & deq_line_onehot[l]),
        .branch_clr (branch_clr[b][l]),
        .mark_last  (mark_last[b][l]),
        .wb_ev      (wb_ev),
        .entry_valid(slot_valid[b][l]),
        .entry_uop  (slot_uop[b][l])
      );
      assign slot_bits[b][l] = {slot_valid[b][l], slot_uop[b][l]};
    end

    // head line read: one-hot mux over the 16 lines of this bank
    ttg_onehot_mux #(
      .N(ROB_LINE_NUM),
      .W(SLOT_W)
    ) u_head_mux (
      .sel (deq_line_onehot),
      .data(slot_bits[b]),
      .out (head_bits[b])
    );
    assign head_valid[b] = head_bits[b][ROB_ENTRY_W];
    assign head_uop[b]   = head_bits[b][ROB_ENTRY_W-1:0];
  end

endmodule

`default_nettype wire
