// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_stlf: check_stlf over the stores older than one load, youngest first)
`default_nettype none

// For one load: the youngest older store that cannot be skipped decides.
//   skipped      : suppress_write (cancelled store)  or  no address overlap (disjoint, address known)
//   decides RETRY: Allocated (no address yet), address unknown, partial overlap, covering SC not (yet) successful,
//                  covering store without data
//   decides FWD  : covering store with data  -> forwarded data
//   no decider   : the load goes to the DCache
module lsu_stlf_match
  import lsu_pkg::*;
(
  input  logic [31:0]      ld_paddr,
  input  logic [2:0]       ld_func3,
  input  logic [RIW-1:0]   snap_idx,
  input  logic             snap_flag,
  input  logic [RIW-1:0]   stq_head,
  input  logic             stq_head_flag,
  input  st_state_t        st_st        [SQ],
  input  logic [SQ-1:0]    st_suppress,
  input  logic [SQ-1:0]    st_paddr_valid,
  input  logic [31:0]      st_paddr     [SQ],
  input  logic [2:0]       st_func3     [SQ],
  input  logic [SQ-1:0]    st_data_valid,
  input  logic [31:0]      st_data      [SQ],
  input  logic [SQ-1:0]    st_is_lrsc,
  input  logic [SQ-1:0]    st_sc_pass,
  output logic [RCW-1:0]   older_cnt,           // stores older than the load = distance head -> snapshot
  output logic             res_retry,
  output logic             res_fwd,             // neither retry nor fwd: DCache
  output logic [31:0]      fwd_data
);

  logic [RIW:0]  age_dist;
  logic [SQ-1:0] older, decider, retry_slot;
  logic [SQ-1:0] decider_pos, rev_pos, rev_first, last_pos, sel_slot;
  logic          any_decider;
  logic [31:0]   sel_paddr, sel_data;
  logic [31:0]   paddr_in [SQ], data_in [SQ];

  assign age_dist      = {snap_flag, snap_idx} - {stq_head_flag, stq_head};
  assign older_cnt = RCW'(age_dist);

  for (genvar s = 0; s < SQ; s++) begin : g_slot
    logic [1:0] cls;
    logic       is_alloc, covers_ok;
    assign older[s]    = {1'b0, RIW'(RIW'(s) - stq_head)} < age_dist;
    assign cls         = stlf_class(ld_paddr, ld_func3[1:0], st_paddr[s], st_func3[s][1:0]);
    assign is_alloc    = st_st[s] == ST_ALLOCATED;
    assign covers_ok   = !(st_is_lrsc[s] && !st_sc_pass[s]) && st_data_valid[s];
    assign decider[s]  = older[s] && !st_suppress[s] && (is_alloc || !st_paddr_valid[s] || cls != 2'd0);
    assign retry_slot[s] = is_alloc || !st_paddr_valid[s] || cls == 2'd2 || !covers_ok;
    assign paddr_in[s] = st_paddr[s];
    assign data_in[s]  = st_data[s];
  end

  // youngest decider = highest position (head order) among the deciders
  assign decider_pos = rotr_rn(decider, stq_head);
  for (genvar j = 0; j < SQ; j++) begin : g_rev
    assign rev_pos[j] = decider_pos[SQ-1-j];
    assign last_pos[j] = rev_first[SQ-1-j];
  end
  ttg_first_set #(.N(SQ)) u_last (.req(rev_pos), .onehot(rev_first), .any(any_decider));
  assign sel_slot = rotl_rn(last_pos, stq_head);

  ttg_onehot_mux #(.N(SQ), .W(32)) u_paddr (.sel(sel_slot), .data(paddr_in), .out(sel_paddr));
  ttg_onehot_mux #(.N(SQ), .W(32)) u_data  (.sel(sel_slot), .data(data_in),  .out(sel_data));

  assign res_retry = any_decider && (|(sel_slot & retry_slot));
  assign res_fwd   = any_decider && !(|(sel_slot & retry_slot));
  assign fwd_data  = extract_data(sel_data, 2'(ld_paddr - sel_paddr), ld_func3);

endmodule

`default_nettype wire
