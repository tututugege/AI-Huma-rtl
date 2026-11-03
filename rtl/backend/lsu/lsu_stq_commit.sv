// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_stq_commit: ROB-committed stores -> cm_go events)
`default_nettype none

// The k-th accepted commit must hit the commit pointer (head + ccount) advanced by the commits accepted before it.
// The entry turns cm_go into Committed / Done (see lsu_stq_ent).
module lsu_stq_commit
  import lsu_pkg::*;
(
  input  logic [NCM-1:0]   cm_valid,
  input  logic [4:0]       cm_type     [NCM],
  input  logic [4:0]       cm_amo_op   [NCM],     // func7[6:2]
  input  logic [SQW-1:0]   cm_stq_idx  [NCM],
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_ccount,
  input  st_state_t        st_q        [SQ],
  output logic [SQ-1:0]    cm_go,
  output logic [RCW-1:0]   ccount_cm              // ccount after this cycle's commits (saturates at SQ)
);

  // is_store(): STORE, or AMO other than LR
  logic [NCM-1:0] cm_store, cm_match;
  logic [RIW-1:0] expect_idx [NCM];
  logic [RCW-1:0] n_acc [NCM+1];

  always_comb begin
    n_acc[0] = '0;
    for (int i = 0; i < NCM; i++) begin
      cm_store[i]   = cm_valid[i] && (cm_type[i] == INST_STORE || (cm_type[i] == INST_AMO && cm_amo_op[i] != AMO_LR));
      expect_idx[i] = stq_head + RIW'(stq_ccount) + RIW'(n_acc[i]);
      cm_match[i]   = cm_store[i] && cm_stq_idx[i] == expect_idx[i] && st_q[cm_stq_idx[i]] == ST_WAIT_COMMIT;
      n_acc[i+1]    = n_acc[i] + RCW'(cm_match[i]);
    end
  end

  for (genvar s = 0; s < SQ; s++) begin : g_entry
    logic [NCM-1:0] by_port;
    for (genvar i = 0; i < NCM; i++) begin : g_port
      assign by_port[i] = cm_match[i] && cm_stq_idx[i] == SQW'(s);
    end
    assign cm_go[s] = |by_port;
  end
  assign ccount_cm = (stq_ccount + n_acc[NCM] > RCW'(SQ)) ? RCW'(SQ) : stq_ccount + n_acc[NCM];

endmodule

`default_nettype wire
