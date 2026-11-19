// Ref: front-end/icache/icache.cpp  GenericTable<RegfileTablePolicy> data/tag/valid +
// ICacheLookupMetaPackKernel.h (lookup meta pack)
`default_nettype none

// I-cache arrays: 8 ways x 64 sets of {tag, valid, 64-byte line}.  Zero-latency register-file style: the read port is
// asynchronous and sees the array as it was at the start of the cycle (the table write is applied at the clock edge);
// the line of the hit way is selected here so the FSM never sees the other seven.
// Storage is written like a memory (01 section 3.1): one write port, one way per write; valid bits are a register
// vector with a whole-cache clear (fence.i -> invalidate_all clears only valid, not tag/data).
// Replacement (SRRIP, docs/modules/icache.md section 5.2): a 2-bit RRPV per way and set, read with the tags; a hit sets
// the way to 0, a refill ages the set until its largest RRPV is 3 and gives the refilled way 2; the victim is the way
// with the largest RRPV (lowest way among equals).  Reset clears it, fence.i does not.
module icache_arr import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // read request: the set of the request being looked up
  input  logic                    rd_en,          // table response valid (C++ data_read.enable)
  input  logic [IC_IDX_W-1:0]     rd_index,
  input  logic                    cmp_valid,      // compare against cmp_tag this cycle (C++ compare context)
  input  logic [IC_TAG_W-1:0]     cmp_tag,
  output logic                    hit,            // lookup_hit_valid_w
  output logic [IC_LINE_W-1:0]    hit_line,       // line of the hit way (meaningful when hit)
  output logic                    has_invalid,    // some way of the set is invalid (response valid only)
  output logic [IC_WAY_W-1:0]     first_invalid,  // lowest invalid way
  output logic [IC_WAY_W-1:0]     repl_way,       // SRRIP victim of the read set
  // write port (refill)
  input  logic                    we,
  input  logic [IC_IDX_W-1:0]     w_index,
  input  logic [IC_WAY_W-1:0]     w_way,
  input  logic [IC_TAG_W-1:0]     w_tag,
  input  logic [IC_LINE_W-1:0]    w_line,
  input  logic                    inv_all
);

  logic [IC_LINE_W-1:0] data_q  [IC_WAYS][IC_SETS];
  logic [IC_TAG_W-1:0]  tag_q   [IC_WAYS][IC_SETS];
  logic [IC_SETS-1:0]   valid_q [IC_WAYS];
  logic [IC_RB-1:0]     repl_q  [IC_SETS];

  logic [IC_WAYS-1:0]   way_valid, way_match, way_invalid, hit_onehot, invalid_onehot;
  logic [IC_LINE_W-1:0] way_line [IC_WAYS];
  logic                 hit_any, invalid_any;

  for (genvar w = 0; w < IC_WAYS; w++) begin : g_way
    assign way_valid[w] = valid_q[w][rd_index];
    assign way_line[w]  = data_q[w][rd_index];
    assign way_match[w] = way_valid[w] && (tag_q[w][rd_index] == cmp_tag);

    always_ff @(posedge clk) begin
      if (we && w_way == IC_WAY_W'(w)) begin
        data_q[w][w_index] <= w_line;
        tag_q[w][w_index]  <= w_tag;
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n || inv_all)                   valid_q[w] <= '0;
      else if (we && w_way == IC_WAY_W'(w))    valid_q[w][w_index] <= 1'b1;
    end
  end

  // lowest matching way hits (compare only when asked and the table answered); lowest invalid way is the fill target
  assign way_invalid = ~way_valid;
  ttg_first_set #(.N(IC_WAYS)) u_hit (
    .req(way_match & {IC_WAYS{cmp_valid && rd_en}}), .onehot(hit_onehot), .any(hit_any));
  ttg_first_set #(.N(IC_WAYS)) u_inv (.req(way_invalid), .onehot(invalid_onehot), .any(invalid_any));

  ttg_onehot_mux #(.N(IC_WAYS), .W(IC_LINE_W)) u_line (.sel(hit_onehot), .data(way_line), .out(hit_line));

  logic [IC_WAY_W-1:0] first_invalid_idx;
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_inv_idx (.onehot(invalid_onehot), .idx(first_invalid_idx));

  // ---- SRRIP state ----
  logic [IC_WAY_W-1:0] hit_idx;
  logic [IC_RB-1:0]    rrow, wrow, nrow;
  logic [1:0]          mx;
  logic [3:0][IC_WAYS-1:0] at;
  logic [3:0][IC_WAYS-1:0] at_oh;
  /* verilator lint_off UNUSEDSIGNAL */   // level 0 is the fall-back: some way always has the largest RRPV
  logic [3:0]          at_any;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [3:0][IC_WAY_W-1:0] at_way;
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_hit_idx (.onehot(hit_onehot), .idx(hit_idx));
  assign rrow = repl_q[rd_index];
  assign wrow = repl_q[w_index];
  always_comb begin
    for (int v = 0; v < 4; v++)
      for (int w = 0; w < IC_WAYS; w++) at[v][w] = rrow[2 * w +: 2] == 2'(v);
  end
  for (genvar v = 0; v < 4; v++) begin : g_lvl
    ttg_first_set #(.N(IC_WAYS)) u_first (.req(at[v]), .onehot(at_oh[v]), .any(at_any[v]));
    ttg_onehot_to_idx #(.N(IC_WAYS)) u_idx (.onehot(at_oh[v]), .idx(at_way[v]));
  end
  always_comb begin
    repl_way = at_way[0];
    if (at_any[3]) repl_way = at_way[3];
    else if (at_any[2]) repl_way = at_way[2];
    else if (at_any[1]) repl_way = at_way[1];
  end
  // new row: a refill (we) ages w_index's row and inserts at 2; a hit clears the hit way of rd_index's row (never
  // in the same cycle: hits happen in IDLE, refills in the miss states)
  always_comb begin
    mx = 2'd0;
    for (int w = 0; w < IC_WAYS; w++) if (wrow[2 * w +: 2] > mx) mx = wrow[2 * w +: 2];
    nrow = rrow;
    if (we) begin
      for (int w = 0; w < IC_WAYS; w++) nrow[2 * w +: 2] = wrow[2 * w +: 2] + (2'd3 - mx);
      nrow[2 * w_way +: 2] = 2'd2;
    end else begin
      nrow[2 * hit_idx +: 2] = 2'd0;
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < IC_SETS; i++) repl_q[i] <= '0;
    end else if (we) begin
      repl_q[w_index] <= nrow;
    end else if (hit_any) begin
      repl_q[rd_index] <= nrow;
    end
  end

  assign hit           = hit_any;
  assign has_invalid   = rd_en && invalid_any;
  assign first_invalid = first_invalid_idx;

endmodule

`default_nettype wire
