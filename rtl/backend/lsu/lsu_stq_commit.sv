// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_stq_commit: ROB-committed stores become Committed / Done)
`default_nettype none

module lsu_stq_commit
  import lsu_pkg::*;
(
  input  logic [NCM-1:0]   cm_valid,
  input  logic [4:0]       cm_type     [NCM],
  input  logic [4:0]       cm_amo_op   [NCM],     // func7[6:2]
  input  logic [SQW-1:0]   cm_stq_idx  [NCM],
  input  logic             flush,
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_ccount_i,
  input  st_state_t        st_st_i       [SQ],
  input  logic [SQ-1:0]    st_is_lrsc,
  input  logic [SQ-1:0]    st_sc_pass,
  input  logic [SQ-1:0]    st_suppress_i,
  output st_state_t        st_st_o       [SQ],
  output logic [SQ-1:0]    st_suppress_o,
  output logic [RCW-1:0]   stq_ccount_o
);

  // is_store(): STORE, or AMO other than LR
  logic [NCM-1:0] cm_store, cm_match;
  logic [RIW-1:0] expect_idx [NCM];
  logic [RCW-1:0] n_acc [NCM+1];

  // The k-th accepted commit must hit the commit pointer (head + ccount) advanced by the commits accepted before it.
  always_comb begin
    n_acc[0] = '0;
    for (int i = 0; i < NCM; i++) begin
      cm_store[i]   = cm_valid[i] && (cm_type[i] == INST_STORE || (cm_type[i] == INST_AMO && cm_amo_op[i] != AMO_LR));
      expect_idx[i] = stq_head + RIW'(stq_ccount_i) + RIW'(n_acc[i]);
      cm_match[i]   = cm_store[i] && cm_stq_idx[i] == expect_idx[i] && st_st_i[cm_stq_idx[i]] == ST_WAIT_COMMIT;
      n_acc[i+1]    = n_acc[i] + RCW'(cm_match[i]);
    end
  end

  logic [SQ-1:0] hit;
  for (genvar s = 0; s < SQ; s++) begin : g_entry
    logic [NCM-1:0] by_port;
    logic           to_done;
    for (genvar i = 0; i < NCM; i++) begin : g_port
      assign by_port[i] = cm_match[i] && cm_stq_idx[i] == SQW'(s);
    end
    assign hit[s]           = |by_port;
    assign to_done          = flush || (st_is_lrsc[s] && !st_sc_pass[s]);
    assign st_st_o[s]       = !hit[s] ? st_st_i[s] : (to_done ? ST_DONE : ST_COMMITTED);
    assign st_suppress_o[s] = st_suppress_i[s] || (hit[s] && to_done);
  end

  assign stq_ccount_o = (stq_ccount_i + n_acc[NCM] > RCW'(SQ)) ? RCW'(SQ) : stq_ccount_i + n_acc[NCM];

endmodule

`default_nettype wire
