// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (enqueue_*(): append at slot (head + count) % N, count++)
`default_nettype none

// NA candidates in priority order; the enabled ones are compacted and appended in that order.
module lsu_ring_app
  import lsu_pkg::*;
#(
  parameter int NA = 4
) (
  input  lsu_ring_t        ring_i,
  input  logic [NA-1:0]    app_en,
  input  logic [RIW-1:0]   app_idx [NA],
  output lsu_ring_t        ring_o
);

  localparam int AW = $clog2(NA + 1);
  logic [AW-1:0]  rank [NA];
  logic [AW-1:0]  total;
  logic [RIW-1:0] tail;
  logic [RIW-1:0] app_slot [NA];

  lsu_rank #(.N(NA)) u_rank (.bits(app_en), .rank(rank));
  ttg_popcount #(.N(NA), .CW(AW)) u_total (.bits(app_en), .count(total));

  assign tail = ring_i.head + RIW'(ring_i.count);
  for (genvar k = 0; k < NA; k++) begin : g_slot
    assign app_slot[k] = tail + RIW'(rank[k]);
  end

  always_comb begin
    ring_o = ring_i;
    for (int k = 0; k < NA; k++) begin
      if (app_en[k]) begin
        ring_o.valid[app_slot[k]] = 1'b1;
        ring_o.idx[app_slot[k]]   = app_idx[k];
      end
    end
    ring_o.count = ring_i.count + RCW'(total);
  end

endmodule

`default_nettype wire
