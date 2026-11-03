// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_tlb_out: first NP WaitTlb entries of the wait_mmu window -> MMU ports)
`default_nettype none

module lsu_tlb_sel
  import lsu_pkg::*;
#(
  parameter int NP = 4
) (
  input  lsu_ring_t        wait_i,
  input  logic [RN-1:0]    wait_tlb,           // per LDQ/STQ entry: state == WaitTlb
  input  logic [31:0]      vaddr   [RN],
  output logic [NP-1:0]    req_valid,
  output logic [31:0]      req_vaddr     [NP],
  output logic [RIW-1:0]   req_entry_idx [NP],
  output logic [RIW-1:0]   req_wait_idx  [NP]
);

  logic [WIN-1:0] valid_w, cand;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank [WIN];

  lsu_ring_win u_win (.ring(wait_i), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_cand
    assign cand[p] = valid_w[p] && wait_tlb[idx_w[p]];
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank (.bits(cand), .rank(rank));

  always_comb begin
    for (int k = 0; k < NP; k++) begin
      req_valid[k]     = 1'b0;
      req_vaddr[k]     = '0;
      req_entry_idx[k] = '0;
      req_wait_idx[k]  = '0;
      for (int p = 0; p < WIN; p++) begin
        if (cand[p] && rank[p] == RCW'(k)) begin
          req_valid[k]     = 1'b1;
          req_vaddr[k]     = vaddr[idx_w[p]];
          req_entry_idx[k] = idx_w[p];
          req_wait_idx[k]  = wait_i.head + RIW'(p);
        end
      end
    end
  end

endmodule

`default_nettype wire
