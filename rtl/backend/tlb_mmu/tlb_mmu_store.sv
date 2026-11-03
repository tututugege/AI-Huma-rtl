// Ref: back-end/Lsu/TlbMmu.cpp  class TlbMmu (tlb_entries_, repl_ptr_, seq, clear_tlb_entries)
`default_nettype none

// TLB array: fully associative, round-robin replacement. Written only by a refill; SFENCE.VMA (fence) clears every
// valid bit
// and the replacement pointer. A refill in the same cycle as a fence is dropped (C++ seq() returns after the flush).
module tlb_mmu_store import tlb_mmu_pkg::*; #(
  parameter int ENTRIES = 64
) (
  input  logic clk,
  input  logic rst_n,
  input  logic fence,
  input  logic refill_valid,
  input  tlb_mmu_entry_t refill,
  output logic [ENTRIES-1:0] entry_valid,
  output tlb_mmu_entry_t entry [ENTRIES]
);

  localparam int SLOT_W = $clog2(ENTRIES);

`ifndef SYNTHESIS
  // the replacement pointer wraps by itself: depth must be a power of two (C++ uses % capacity)
  if (ENTRIES < 2 || (ENTRIES & (ENTRIES - 1)) != 0) begin : g_check
    $error("tlb_mmu_store: ENTRIES must be a power of two");
  end
`endif

  logic [ENTRIES-1:0]  entry_valid_q, entry_valid_d;
  tlb_mmu_entry_t      entry_q [ENTRIES];
  tlb_mmu_entry_t      entry_d [ENTRIES];
  logic [SLOT_W-1:0]   repl_q, repl_d;
  logic                write_en;

  assign write_en = refill_valid && !fence;

  // Ref: TlbMmu::seq (flush_pending_ branch, then refill_comb_ commit)
  always_comb begin
    entry_valid_d = entry_valid_q;
    repl_d = repl_q;
    for (int i = 0; i < ENTRIES; i++) entry_d[i] = entry_q[i];
    if (fence) begin
      entry_valid_d = '0;
      repl_d = '0;
    end else if (write_en) begin
      entry_valid_d[repl_q] = 1'b1;
      entry_d[repl_q] = refill;
      repl_d = repl_q + SLOT_W'(1);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      entry_valid_q <= '0;
      repl_q <= '0;
      for (int i = 0; i < ENTRIES; i++) entry_q[i] <= '0;
    end else begin
      entry_valid_q <= entry_valid_d;
      repl_q <= repl_d;
      for (int i = 0; i < ENTRIES; i++) entry_q[i] <= entry_d[i];
    end
  end

  assign entry_valid = entry_valid_q;
  for (genvar i = 0; i < ENTRIES; i++) begin : g_entry
    assign entry[i] = entry_q[i];
  end

endmodule

`default_nettype wire
