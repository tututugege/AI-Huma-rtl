// Ref: back-end/Rob.cpp  class Rob  (one slot of entry[bank][line]; next-state of entry_1 over comb_commit..comb_flush)
`default_nettype none

module rob_entry
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
#(
  parameter int ENTRY_IDX = 0  // rob_idx of this slot = line * ROB_BANK_NUM + bank
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       flush,            // Rob::comb_flush
  input  logic       fire_we,          // Rob::comb_fire writes this slot
  input  rob_entry_t fire_uop,
  input  logic       commit_clr,       // Rob::comb_commit retires this slot
  input  logic       branch_clr,       // Rob::comb_branch kills this slot (younger than the redirect point)
  input  logic       mark_last,        // Rob::comb_branch: this is the redirecting branch, set ftq_is_last
  input  rob_event_t wb_ev [ISSUE_WIDTH],
  output logic       entry_valid,
  output rob_entry_t entry_uop
);

  logic       valid_q, valid_d;
  rob_entry_t uop_q, uop_d;

  // Ref: Rob::comb_complete / comb_branch / comb_fire (uop payload, later stage overrides earlier stage)
  always_comb begin
    uop_d = uop_q;
    // write-backs are applied in ascending port order, like the for (i < ISSUE_WIDTH) loop; no valid check on purpose
    for (int p = 0; p < ISSUE_WIDTH; p++) begin
      if (wb_ev[p].valid && wb_ev[p].rob_idx == ROB_IDX_WIDTH'(ENTRY_IDX)) uop_d = rob_apply_event(uop_d, wb_ev[p]);
    end
    if (mark_last) uop_d.ftq_is_last = 1'b1;
    if (fire_we) uop_d = fire_uop;
  end

  // Ref: Rob::comb_commit (clear) -> comb_branch (clear) -> comb_fire (set) -> comb_flush (clear): last writer wins
  always_comb begin
    valid_d = valid_q;
    if (commit_clr) valid_d = 1'b0;
    if (branch_clr) valid_d = 1'b0;
    if (fire_we) valid_d = 1'b1;
    if (flush) valid_d = 1'b0;
  end

  // Ref: Rob::seq
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      uop_q   <= '0;
    end else begin
      valid_q <= valid_d;
      uop_q   <= uop_d;
    end
  end

  assign entry_valid = valid_q;
  assign entry_uop   = uop_q;

endmodule

`default_nettype wire
