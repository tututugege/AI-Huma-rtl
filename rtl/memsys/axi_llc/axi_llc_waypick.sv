`default_nettype none
// Ref: AXI_LLC.cpp  pick_unreserved_way (LLC_REPL = srrip)
// Way selection for a lookup miss: the first invalid way unless an in-flight refill / write-back owns it, otherwise
// the unreserved way with the largest RRPV (the lowest way among equals).  ok = 0 when every way is reserved.
module axi_llc_waypick
  import axi_llc_pkg::*;
(
  input  logic inv_any,
  input  logic [WB-1:0] inv_way,
  input  logic [WAYS-1:0] reserved,
  input  logic [RB-1:0] repl,
  output logic ok,
  output logic [WB-1:0] way
);
  logic inv_ok;
  logic [3:0][WAYS-1:0] at;                    // at[v][w]: way w is unreserved and has RRPV v
  logic [3:0][WAYS-1:0] at_oh;
  logic [3:0] at_any;
  logic [3:0][WB-1:0] at_way;

  always_comb begin
    for (int v = 0; v < 4; v++)
      for (int w = 0; w < WAYS; w++) at[v][w] = !reserved[w] && repl[2 * w +: 2] == 2'(v);
  end
  for (genvar v = 0; v < 4; v++) begin : g_lvl
    ttg_first_set #(.N(WAYS)) u_first (.req(at[v]), .onehot(at_oh[v]), .any(at_any[v]));
    ttg_onehot_to_idx #(.N(WAYS), .IDXW(WB)) u_idx (.onehot(at_oh[v]), .idx(at_way[v]));
  end

  always_comb begin
    inv_ok = inv_any && !reserved[inv_way];
    ok = inv_ok || (|at_any);
    way = at_way[0];
    if (at_any[3]) way = at_way[3];
    else if (at_any[2]) way = at_way[2];
    else if (at_any[1]) way = at_way[1];
    if (inv_ok) way = inv_way;
  end
endmodule

`default_nettype wire
