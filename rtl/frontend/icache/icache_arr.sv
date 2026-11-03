// Ref: front-end/icache/icache.cpp  GenericTable<RegfileTablePolicy> data/tag/valid +
// ICacheLookupMetaPackKernel.h (lookup meta pack)
`default_nettype none

// I-cache arrays: 8 ways x 64 sets of {tag, valid, 64-byte line}.  Zero-latency register-file style: the read port is
// asynchronous and sees the array as it was at the start of the cycle (the table write is applied at the clock edge);
// the line of the hit way is selected here so the FSM never sees the other seven.
// Storage is written like a memory (01 section 3.1): one write port, one way per write; valid bits are a register
// vector with a whole-cache clear (fence.i -> invalidate_all clears only valid, not tag/data).
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

  assign hit           = hit_any;
  assign has_invalid   = rd_en && invalid_any;
  assign first_invalid = first_invalid_idx;

endmodule

`default_nettype wire
