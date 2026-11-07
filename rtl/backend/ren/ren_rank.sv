// Ref: back-end/Ren.cpp  class Ren  Ren::comb_fire (commit part: free-list write offsets)
`default_nettype none

// For a set of commit slots: how many selected slots precede each slot (write offset into the free list) and how many
// there are in total.
module ren_rank
  import ttg_cfg_pkg::*;
#(
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic [C-1:0]  sel,
  output logic [CW-1:0] rank [C],
  output logic [CW-1:0] total
);

  for (genvar k = 0; k < C; k++) begin : g_slot
    logic [C-1:0] before_mask;
    assign before_mask = sel & ~({C{1'b1}} << k);
    ttg_popcount #(.N(C)) u_rank (.bits(before_mask), .count(rank[k]));
  end

  ttg_popcount #(.N(C)) u_total (.bits(sel), .count(total));

endmodule

`default_nettype wire
