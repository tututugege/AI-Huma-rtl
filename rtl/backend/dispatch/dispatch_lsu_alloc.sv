// Ref: back-end/Dispatch.cpp  Dispatch::comb_alloc (LDQ / STQ part)
`default_nettype none

// Assigns store-queue and load-queue entries to the loads/stores of the group, in program order.
//   * stores take consecutive STQ entries from stq_tail while the queue has free entries;
//   * loads take the LSU-provided free LDQ entries ldq_alloc_idx[0..], one per load, in order;
//   * every load also records the STQ position of the youngest older store (stq_idx/stq_flag).
// A load/store that gets no entry has lsu_ok = 0 and cannot fire.
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
  output logic                      lsu_ok  [NUM_SLOTS],
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

  // ---- per-lane results ----
  // A lane can only fire when every older lane fired, so each lane is judged on its own rank:
  //   store: free STQ entries > rank;   load: LDQ port `rank` is usable (free count and valid from the LSU).
  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    logic                 ld_granted;
    logic                 st_granted;
    logic [STQ_POS_W-1:0] stq_pos;    // STQ ring position after the older stores of the group

    // Ref: Dispatch::comb_alloc (load_alloc_count / store_alloc_count conditions)
    always_comb begin
      ld_granted = want_ld[i] && (LDQ_FREE_W'(ld_rank[i]) < ldq_free) && ldq_alloc_valid[ld_rank[i][LDQ_PORT_W-1:0]];
      st_granted = want_st[i] && (STQ_FREE_W'(st_rank[i]) < stq_free);
      stq_pos    = STQ_POS_W'(stq_tail) + STQ_POS_W'(st_rank[i]);
      lsu_ok[i] = (!want_ld[i] || ld_granted) && (!want_st[i] || st_granted);
      // memory ops record their STQ position (loads: youngest older store); other ops carry 0
      stq_idx[i]  = (is_load[i] || is_store[i]) ? stq_pos[STQ_IDX_WIDTH-1:0] : '0;
      stq_flag[i] = (is_load[i] || is_store[i]) && (stq_tail_flag ^ stq_pos[STQ_IDX_WIDTH]);
      ldq_idx[i]  = is_load[i] ? ldq_alloc_idx[ld_rank[i][LDQ_PORT_W-1:0]] : '0;
      st_port_sel[i] = st_granted ? (STQ_PORTS'(1) << st_rank[i][STQ_PORT_W-1:0]) : '0;
      ld_port_sel[i] = ld_granted ? (LDQ_PORTS'(1) << ld_rank[i][LDQ_PORT_W-1:0]) : '0;
    end
  end

endmodule

`default_nettype wire
