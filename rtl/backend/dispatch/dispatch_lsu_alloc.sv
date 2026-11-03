// Ref: back-end/Dispatch.cpp  Dispatch::comb_alloc (LDQ / STQ part)
`default_nettype none

// Assigns store-queue and load-queue entries to the loads/stores of the group, in program order.
//   * stores take consecutive STQ entries from stq_tail while the queue has free entries;
//   * loads take the LSU-provided free LDQ entries ldq_alloc_idx[0..], one per load, in order;
//   * every load also records the STQ position of the youngest older store (stq_idx/stq_flag).
// A load/store that gets no entry marks its lane not valid for the ROB (rob_valid = 0).
module dispatch_lsu_alloc
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                      inst_valid [NUM_SLOTS],
  input  logic                      is_load    [NUM_SLOTS],
  input  logic                      is_store   [NUM_SLOTS],
  input  logic [STQ_IDX_WIDTH-1:0]  stq_tail,
  input  logic                      stq_tail_flag,
  input  logic [STQ_FREE_W-1:0]     stq_free,
  input  logic [LDQ_FREE_W-1:0]     ldq_free,
  input  logic [LDQ_IDX_WIDTH-1:0]  ldq_alloc_idx   [LDQ_PORTS],
  input  logic                      ldq_alloc_valid [LDQ_PORTS],
  output logic                      rob_valid  [NUM_SLOTS],
  output logic [STQ_IDX_WIDTH-1:0]  stq_idx    [NUM_SLOTS],
  output logic                      stq_flag   [NUM_SLOTS],
  output logic [LDQ_IDX_WIDTH-1:0]  ldq_idx    [NUM_SLOTS],
  output logic [STQ_PORTS-1:0]      st_port_sel [NUM_SLOTS],  // one-hot STQ request port of a granted store
  output logic [LDQ_PORTS-1:0]      ld_port_sel [NUM_SLOTS]   // one-hot LDQ request port of a granted load
);

  localparam int RANK_W = $clog2(NUM_SLOTS + 1);

  logic [NUM_SLOTS-1:0] want_ld;     // valid load-type lanes
  logic [NUM_SLOTS-1:0] want_st;     // valid store-type lanes
  logic [RANK_W-1:0]    ld_rank [NUM_SLOTS];   // number of older load-type lanes
  logic [RANK_W-1:0]    st_rank [NUM_SLOTS];   // number of older store-type lanes

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      want_ld[i] = inst_valid[i] && is_load[i];
      want_st[i] = inst_valid[i] && is_store[i];
    end
  end

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_rank
    localparam logic [NUM_SLOTS-1:0] OLDER = NUM_SLOTS'((1 << i) - 1);
    ttg_popcount #(.N(NUM_SLOTS)) u_ld_rank (.bits(want_ld & OLDER), .count(ld_rank[i]));
    ttg_popcount #(.N(NUM_SLOTS)) u_st_rank (.bits(want_st & OLDER), .count(st_rank[i]));
  end

  // ---- LDQ: the k-th load is granted iff port conditions hold for ports 0..k (all older loads granted) ----
  logic [LDQ_PORTS-1:0] ldq_port_ok;      // per-port availability
  logic [LDQ_PORTS-1:0] ldq_port_missing; // ports that cannot be used
  logic [LDQ_PORTS-1:0] ldq_first_missing;
  logic                 ldq_any_missing;
  logic [LDQ_PORTS-1:0] ldq_granted_upto; // ports 0..k all usable

  always_comb begin
    for (int k = 0; k < LDQ_PORTS; k++) begin
      ldq_port_ok[k] = (LDQ_FREE_W'(k) < ldq_free) && (k < IQ_DISPATCH_WIDTH) && ldq_alloc_valid[k];
    end
    ldq_port_missing = ~ldq_port_ok;
  end

  ttg_first_set #(.N(LDQ_PORTS)) u_ldq_first_missing (
    .req(ldq_port_missing), .onehot(ldq_first_missing), .any(ldq_any_missing));

  always_comb begin
    // bits strictly below the first missing port; all ports if none is missing
    ldq_granted_upto = ldq_any_missing ? (ldq_first_missing - LDQ_PORTS'(1)) : '1;
  end

  // ---- per-lane results ----
  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    logic                     ld_granted;
    logic                     st_granted;
    logic [STQ_FREE_W-1:0]    older_stores_granted;  // stores before this lane that got an entry
    logic [STQ_POS_W-1:0]     stq_pos;

    // Ref: Dispatch::comb_alloc (load_alloc_count / store_alloc_count conditions)
    always_comb begin
      ld_granted = want_ld[i] && ldq_granted_upto[ld_rank[i][LDQ_PORT_W-1:0]];
      st_granted = want_st[i] && (STQ_FREE_W'(st_rank[i]) < stq_free) && (st_rank[i] < RANK_W'(STQ_PORTS));
      older_stores_granted = (STQ_FREE_W'(st_rank[i]) < stq_free) ? STQ_FREE_W'(st_rank[i]) : stq_free;
      stq_pos = STQ_POS_W'(stq_tail) + STQ_POS_W'(older_stores_granted);
    end

    always_comb begin
      rob_valid[i] = inst_valid[i] && (!is_load[i] || ld_granted) && (!is_store[i] || st_granted);
      // a load always records the STQ position; a pure store only when it was granted a slot
      stq_idx[i]  = '0;
      stq_flag[i] = 1'b0;
      if (want_ld[i] || st_granted) begin
        stq_idx[i]  = stq_pos[STQ_IDX_WIDTH-1:0];
        stq_flag[i] = stq_tail_flag ^ stq_pos[STQ_IDX_WIDTH];
      end
      ldq_idx[i] = ld_granted ? ldq_alloc_idx[ld_rank[i][LDQ_PORT_W-1:0]] : '0;
      st_port_sel[i] = st_granted ? (STQ_PORTS'(1) << st_rank[i][STQ_PORT_W-1:0]) : '0;
      ld_port_sel[i] = ld_granted ? (LDQ_PORTS'(1) << ld_rank[i][LDQ_PORT_W-1:0]) : '0;
    end
  end

endmodule

`default_nettype wire
