// Ref: rtl/common/ttg_first_set.sv (same function, log-depth form when LP_L2[9])
`default_nettype none

// Find-first-set, lowest index has priority.  LP_L2[9] = 0: the common primitive (`req & -req`, a carry chain:
// ABC keeps it about N levels deep).  LP_L2[9] = 1: Kogge-Stone prefix-OR (log2 N levels), the same function.
module lp_ffs
  import lp_pkg::*;
#(
  parameter int N = 8
) (
  input  logic [N-1:0] req,
  output logic [N-1:0] onehot,
  output logic         any
);

  if ((LP_L2 & 512) != 0) begin : g_log
    logic [N-1:0] pre;
    always_comb begin
      pre = req;
      for (int s = 1; s < N; s = s * 2) pre = pre | (pre << s);   // pre[i] = |req[i:0]
      onehot = req & ~(pre << 1);
      any = pre[N-1];
    end
  end else begin : g_chain
    ttg_first_set #(.N(N)) u_fs (.req(req), .onehot(onehot), .any(any));
  end

endmodule

`default_nettype wire
