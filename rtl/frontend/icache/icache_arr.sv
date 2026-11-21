// Ref: front-end/icache/icache_top.cpp  ICacheTop (4-bank 1R1W arrays, Bank B fetch_second, FDIP peek & fill, SRRIP)
`default_nettype none

// 4-bank 1R1W I-cache arrays: 8 ways x 64 sets (partitioned into 4 banks by set[1:0], 16 sets/bank) of
// {tag, valid, 64-byte line} + 2-bit SRRIP RRPV per way.
//   - Port A (demand): asynchronous read at rd_index, hit compare vs cmp_tag, SRRIP hit touch.
//   - Port B (fetch_second): parallel read at b_rd_index (with same-cycle demand refill forwarding) for paired Block B.
//   - FDIP tag peek: cycle-start tag/valid check at fdip_peek_index (no data read, no state update).
//   - Single write port: demand refill (we) has strict priority over FDIP refill (fdip_we).
module icache_arr import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // Port A (demand lookup)
  input  logic                    rd_en,
  input  logic [IC_IDX_W-1:0]     rd_index,
  input  logic                    cmp_valid,
  input  logic [IC_TAG_W-1:0]     cmp_tag,
  output logic                    hit,
  output logic [IC_LINE_W-1:0]    hit_line,
  output logic                    has_invalid,
  output logic [IC_WAY_W-1:0]     first_invalid,
  output logic [IC_WAY_W-1:0]     repl_way,
  // Port B (paired Block B parallel read, with same-cycle demand refill forwarding)
  input  logic [IC_IDX_W-1:0]     b_rd_index,
  input  logic [IC_TAG_W-1:0]     b_cmp_tag,
  output logic                    b_hit,
  output logic [IC_LINE_W-1:0]    b_hit_line,
  // FDIP tag peek (cycle-start arrays, tag/valid only)
  input  logic [IC_IDX_W-1:0]     fdip_peek_index,
  input  logic [IC_TAG_W-1:0]     fdip_peek_tag,
  output logic                    fdip_peek_hit,
  // Demand write port (refill)
  input  logic                    we,
  input  logic [IC_IDX_W-1:0]     w_index,
  input  logic [IC_WAY_W-1:0]     w_way,
  input  logic [IC_TAG_W-1:0]     w_tag,
  input  logic [IC_LINE_W-1:0]    w_line,
  input  logic                    inv_all,
  // FDIP write port (lower priority than demand we / inv_all)
  input  logic                    fdip_we,
  input  logic [IC_IDX_W-1:0]     fdip_w_index,
  input  logic [IC_TAG_W-1:0]     fdip_w_tag,
  input  logic [IC_LINE_W-1:0]    fdip_w_line
);

  logic [IC_LINE_W-1:0] data_q  [IC_WAYS][IC_SETS];
  logic [IC_TAG_W-1:0]  tag_q   [IC_WAYS][IC_SETS];
  logic [IC_SETS-1:0]   valid_q [IC_WAYS];
  logic [IC_RB-1:0]     repl_q  [IC_SETS];

  // ---- Port A (demand) ----
  logic [IC_WAYS-1:0]   way_valid, way_match, way_invalid, hit_onehot, invalid_onehot;
  logic [IC_LINE_W-1:0] way_line [IC_WAYS];
  logic                 hit_any, invalid_any;

  // ---- Port B (fetch_second, with same-cycle demand refill forwarding) ----
  logic [IC_WAYS-1:0]   b_way_match, b_hit_oh;
  logic [IC_LINE_W-1:0] b_way_line [IC_WAYS];
  logic                 b_hit_any;

  // ---- FDIP tag peek & fill resident/invalid check ----
  logic [IC_WAYS-1:0]   fp_match, ff_match, ff_inv, ff_inv_oh;
  logic                 ff_hit_any, ff_inv_any;
  logic [IC_WAY_W-1:0]  ff_inv_idx;

  // ---- Shared single write port ----
  logic                 eff_fdip_we, eff_we;
  logic [IC_IDX_W-1:0]  eff_w_index;
  logic [IC_WAY_W-1:0]  eff_w_way, fdip_w_way;
  logic [IC_TAG_W-1:0]  eff_w_tag;
  logic [IC_LINE_W-1:0] eff_w_line;

  for (genvar w = 0; w < IC_WAYS; w++) begin : g_way
    logic b_fwd;
    logic b_v;
    logic [IC_TAG_W-1:0] b_t;

    assign way_valid[w] = valid_q[w][rd_index];
    assign way_line[w]  = data_q[w][rd_index];
    assign way_match[w] = way_valid[w] && (tag_q[w][rd_index] == cmp_tag);

    assign b_fwd         = !inv_all && we && (w_index == b_rd_index) && (w_way == IC_WAY_W'(w));
    assign b_v           = inv_all ? 1'b0 : (b_fwd ? 1'b1 : valid_q[w][b_rd_index]);
    assign b_t           = b_fwd ? w_tag : tag_q[w][b_rd_index];
    assign b_way_line[w] = b_fwd ? w_line : data_q[w][b_rd_index];
    assign b_way_match[w] = b_v && (b_t == b_cmp_tag);

    assign fp_match[w] = valid_q[w][fdip_peek_index] && (tag_q[w][fdip_peek_index] == fdip_peek_tag);
    assign ff_match[w] = valid_q[w][fdip_w_index] && (tag_q[w][fdip_w_index] == fdip_w_tag);
    assign ff_inv[w]   = !valid_q[w][fdip_w_index];

    always_ff @(posedge clk) begin
      if (eff_we && eff_w_way == IC_WAY_W'(w)) begin
        data_q[w][eff_w_index] <= eff_w_line;
        tag_q[w][eff_w_index]  <= eff_w_tag;
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n || inv_all)                        valid_q[w] <= '0;
      else if (eff_we && eff_w_way == IC_WAY_W'(w)) valid_q[w][eff_w_index] <= 1'b1;
    end
  end

  assign way_invalid = ~way_valid;
  ttg_first_set #(.N(IC_WAYS)) u_hit (
    .req(way_match & {IC_WAYS{cmp_valid && rd_en}}), .onehot(hit_onehot), .any(hit_any));
  ttg_first_set #(.N(IC_WAYS)) u_inv (.req(way_invalid), .onehot(invalid_onehot), .any(invalid_any));
  ttg_onehot_mux #(.N(IC_WAYS), .W(IC_LINE_W)) u_line (.sel(hit_onehot), .data(way_line), .out(hit_line));

  logic [IC_WAY_W-1:0] first_invalid_idx;
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_inv_idx (.onehot(invalid_onehot), .idx(first_invalid_idx));

  ttg_first_set #(.N(IC_WAYS)) u_b_hit (.req(b_way_match), .onehot(b_hit_oh), .any(b_hit_any));
  ttg_onehot_mux #(.N(IC_WAYS), .W(IC_LINE_W)) u_b_line (.sel(b_hit_oh), .data(b_way_line), .out(b_hit_line));

  assign fdip_peek_hit = |fp_match;
  assign ff_hit_any    = |ff_match;
  ttg_first_set #(.N(IC_WAYS)) u_ff_inv (.req(ff_inv), .onehot(ff_inv_oh), .any(ff_inv_any));
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_ff_inv_idx (.onehot(ff_inv_oh), .idx(ff_inv_idx));

  // ---- SRRIP helper: victim of a row ----
  function automatic logic [IC_WAY_W-1:0] srrip_victim(input logic [IC_RB-1:0] row);
    logic [IC_WAY_W-1:0] v;
    logic found;
    v = '0;
    found = 1'b0;
    for (int lvl = 3; lvl >= 0; lvl--) begin
      for (int w = 0; w < IC_WAYS; w++) begin
        if (!found && (row[2 * w +: 2] == 2'(lvl))) begin
          v     = IC_WAY_W'(w);
          found = 1'b1;
        end
      end
    end
    return v;
  endfunction

  function automatic logic [IC_RB-1:0] srrip_fill_row(input logic [IC_RB-1:0] row, input logic [IC_WAY_W-1:0] wy);
    logic [1:0] mx;
    logic [IC_RB-1:0] nr;
    mx = 2'd0;
    for (int w = 0; w < IC_WAYS; w++) if (row[2 * w +: 2] > mx) mx = row[2 * w +: 2];
    for (int w = 0; w < IC_WAYS; w++) nr[2 * w +: 2] = row[2 * w +: 2] + (2'd3 - mx);
    nr[2 * wy +: 2] = 2'd2;
    return nr;
  endfunction

  // ---- SRRIP state ----
  logic [IC_WAY_W-1:0] hit_idx, fdip_repl_way;
  logic [IC_RB-1:0]    rrow, wrow, nrow_we, nrow_hit, fdip_rrow, nrow_fdip;

  ttg_onehot_to_idx #(.N(IC_WAYS)) u_hit_idx (.onehot(hit_onehot), .idx(hit_idx));

  always_comb begin
    rrow     = repl_q[rd_index];
    repl_way = srrip_victim(rrow);
  end

  always_comb begin
    wrow     = repl_q[w_index];
    nrow_we  = srrip_fill_row(wrow, w_way);
    nrow_hit = rrow;
    nrow_hit[2 * hit_idx +: 2] = 2'd0;

    eff_fdip_we   = fdip_we && !we && !inv_all && !ff_hit_any;
    fdip_rrow     = (hit_any && (rd_index == fdip_w_index)) ? nrow_hit : repl_q[fdip_w_index];
    fdip_repl_way = srrip_victim(fdip_rrow);
    fdip_w_way    = ff_inv_any ? ff_inv_idx : fdip_repl_way;
    nrow_fdip     = srrip_fill_row(fdip_rrow, fdip_w_way);

    eff_we      = we || eff_fdip_we;
    eff_w_index = we ? w_index : fdip_w_index;
    eff_w_way   = we ? w_way   : fdip_w_way;
    eff_w_tag   = we ? w_tag   : fdip_w_tag;
    eff_w_line  = we ? w_line  : fdip_w_line;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < IC_SETS; i++) repl_q[i] <= '0;
    end else if (we) begin
      repl_q[w_index] <= nrow_we;
    end else begin
      if (hit_any && (!eff_fdip_we || (rd_index != fdip_w_index))) repl_q[rd_index] <= nrow_hit;
      if (eff_fdip_we) repl_q[fdip_w_index] <= nrow_fdip;
    end
  end

  assign hit           = hit_any;
  assign has_invalid   = rd_en && invalid_any;
  assign first_invalid = first_invalid_idx;
  assign b_hit         = b_hit_any;

endmodule

`default_nettype wire
