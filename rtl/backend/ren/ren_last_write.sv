// Ref: back-end/Ren.cpp  class Ren  ("later slot wins" rule of comb_fire / commit RAT writes)
`default_nettype none

// Highest-index hit wins: models sequential same-cycle overwrites (C++ for-loop order) as a priority select.
module ren_last_write #(
  parameter int N = 8,
  parameter int W = 7
) (
  input  logic [N-1:0] hit,
  input  logic [W-1:0] data [N],
  output logic         any,
  output logic [W-1:0] value
);

  logic [N-1:0] hit_rev;
  logic [N-1:0] pick_rev;
  logic [W-1:0] data_rev [N];

  always_comb begin
    for (int i = 0; i < N; i++) begin
      hit_rev[i]  = hit[N-1-i];
      data_rev[i] = data[N-1-i];
    end
  end

  ttg_first_set #(.N(N)) u_pick (.req(hit_rev), .onehot(pick_rev), .any(any));
  ttg_onehot_mux #(.N(N), .W(W)) u_mux (.sel(pick_rev), .data(data_rev), .out(value));

endmodule

`default_nettype wire
