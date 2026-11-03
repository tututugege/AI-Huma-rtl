// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_check: retire the Done stores at the STQ head)
`default_nettype none

module lsu_retire
  import lsu_pkg::*;
(
  input  logic [RIW-1:0]   head_i,
  input  logic             head_flag_i,
  input  logic [RCW-1:0]   count_i,
  input  logic [RCW-1:0]   ccount_i,
  input  st_state_t        st_st_i [SQ],
  output logic [RIW-1:0]   head_o,
  output logic             head_flag_o,
  output logic [RCW-1:0]   count_o,
  output logic [RCW-1:0]   ccount_o
);

  logic [RCW-1:0] committed, window, n_retire;
  logic [WIN-1:0] not_done, first_not_done;
  logic [RIW:0]   head_sum;
  /* verilator lint_off UNUSEDSIGNAL */  // first_set "any" not needed: n_retire defaults to the window size
  logic           any_not_done;
  /* verilator lint_on UNUSEDSIGNAL */

  assign committed = ccount_i > count_i ? count_i : ccount_i;
  assign window    = committed > RCW'(WIN) ? RCW'(WIN) : committed;
  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign not_done[p] = RCW'(p) >= window || st_st_i[head_i + RIW'(p)] != ST_DONE;
  end
  ttg_first_set #(.N(WIN)) u_first (.req(not_done), .onehot(first_not_done), .any(any_not_done));

  always_comb begin
    n_retire = window;
    for (int p = 0; p < WIN; p++) if (first_not_done[p]) n_retire = RCW'(p);
  end

  assign head_sum    = {1'b0, head_i} + n_retire[RIW:0];
  assign head_o      = head_sum[RIW-1:0];
  assign head_flag_o = head_sum[RIW] ? !head_flag_i : head_flag_i;
  assign count_o     = count_i - n_retire;
  assign ccount_o    = ccount_i - n_retire;

endmodule

`default_nettype wire
