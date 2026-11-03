// Ref: back-end/Exu/Csr.cpp  Csr::comb_exception (cause code selection)
`default_nettype none

// Priority-ordered cause code: the lowest-index asserted condition wins, none -> 0.
module csr_cause_sel #(
  parameter int N = 8
) (
  input  logic [N-1:0] cond,
  input  logic [3:0]   code [N],
  output logic [3:0]   cause_code
);

  logic [N-1:0] first;
  // any is not needed (no condition -> cause 0); named, not empty, because -Wall flags empty pin connections.
  /* verilator lint_off UNUSEDSIGNAL */
  logic         none_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  ttg_first_set #(.N(N)) u_first (.req(cond), .onehot(first), .any(none_unused));
  ttg_onehot_mux #(.N(N), .W(4)) u_mux (.sel(first), .data(code), .out(cause_code));

endmodule

`default_nettype wire
