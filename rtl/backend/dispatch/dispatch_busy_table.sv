// Ref: back-end/Dispatch.cpp  Dispatch::busy_table / busy_table_1 (comb_fire, seq)
`default_nettype none

// Per-physical-register busy bit. A register becomes busy when its producer dispatches and is
// released by the wakeup broadcasts. Set wins over clear (the C++ clears first, then sets).
module dispatch_busy_table
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [TAG_NUM-1:0]       cancel_v,    // wake-up of the previous cycle was wrong (LP_L2): busy again
  input  logic [NUM_WAKE-1:0] wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] wake_preg  [NUM_WAKE],
  input  logic [NUM_SLOTS-1:0] set_valid,   // fired instruction with a destination
  input  logic [PRF_IDX_WIDTH-1:0] set_preg   [NUM_SLOTS],
  output logic [TAG_NUM-1:0]       busy_q
);

  logic [TAG_NUM-1:0] busy_d;
  logic [TAG_NUM-1:0] wake_clear;
  logic [TAG_NUM-1:0] dest_set;

  // Ref: Dispatch::comb_fire (busy_table_1: clear on wakeup, then set on fire)
  always_comb begin
    wake_clear = '0;
    dest_set   = '0;
    for (int p = 0; p < TAG_NUM; p++) begin
      for (int w = 0; w < NUM_WAKE; w++) begin
        wake_clear[p] = wake_clear[p] || (wake_valid[w] && (wake_preg[w] == PRF_IDX_WIDTH'(p)));
      end
      for (int i = 0; i < NUM_SLOTS; i++) begin
        dest_set[p] = dest_set[p] || (set_valid[i] && (set_preg[i] == PRF_IDX_WIDTH'(p)));
      end
    end
    busy_d = dest_set | ((busy_q | cancel_v) & ~wake_clear);
  end

  // Ref: Dispatch::seq
  always_ff @(posedge clk) begin
    if (!rst_n) busy_q <= '0;
    else        busy_q <= busy_d;
  end

endmodule

`default_nettype wire
