// Ref: front-end/icache/icache_top.cpp  ICacheTop (physical 4-bank 1R1W arrays, Bank B fetch_second, FDIP peek & fill, parallel SRRIP)
`default_nettype none

// Physical 4-bank 1R1W I-cache arrays: 8 ways x 64 sets partitioned into 4 banks by set[1:0] (16 sets/bank) of
// {tag, valid, 64-byte line} + 2-bit SRRIP RRPV per way.
//   - Each bank's data_q[8][16] has strictly ONE read port and ONE write port.
//   - Port A (demand) reads bank rd_index[1:0]; Port B (fetch_second) reads bank b_rd_index[1:0] in parallel when
//     b_rd_index[1:0] != rd_index[1:0] (or shares Port A's bank read on same-line pair; ic_pair_ok guarantees no
//     same-bank different-line conflict).
//   - FDIP tag peek / fill resident check inspect tag/valid only (no data read, no state update).
//   - Single write port: demand refill (we) has strict priority over FDIP refill (fdip_we).
module icache_arr import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // Port A (demand lookup)
  input  logic                    rd_en,
  input  logic [IC_IDX_W-1:0]     rd_index,
  input  logic                    cmp_valid,
  input  logic [IC_TAG_W-1:0]     cmp_tag,
  // Next-cycle VIPT set indices for strict 1-cycle synchronous Data SRAM pre-launch
  input  logic [IC_IDX_W-1:0]     next_rd_index,
  input  logic [IC_IDX_W-1:0]     next_b_rd_index,
  output logic                    hit,
  output logic [IC_LINE_W-1:0]    hit_line,
  output logic                    has_invalid,
  output logic [IC_WAY_W-1:0]     first_invalid,
  output logic [IC_WAY_W-1:0]     repl_way,
  // Port B (paired Block B parallel read, with same-cycle demand refill forwarding)
  /* verilator lint_off UNUSEDSIGNAL */  // used by simulation assertion only
  input  logic                    b_rd_valid,
  /* verilator lint_on UNUSEDSIGNAL */
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

  localparam int IC_BANKS  = 4;
  localparam int IC_BK_W   = 2;
  localparam int IC_BSETS  = IC_SETS / IC_BANKS;
  localparam int IC_BROW_W = IC_IDX_W - IC_BK_W;

  // Physical 4-bank arrays: data banks use strict synchronous 1R1W SRAM (ttg_sram_1r1w, WRITE_FIRST=1)
  logic [IC_TAG_W-1:0]  tag_q   [IC_BANKS][IC_WAYS][IC_BSETS];
  logic [IC_BSETS-1:0]  valid_q [IC_BANKS][IC_WAYS];
  logic [IC_RB-1:0]     repl_q  [IC_SETS];

  logic [IC_BK_W-1:0]   a_bk, b_bk, fp_bk, fw_bk, eff_w_bk, next_a_bk, next_b_bk;
  logic [IC_BROW_W-1:0] a_row, b_row, fp_row, fw_row, eff_w_row, next_a_row, next_b_row;

  assign a_bk       = rd_index[IC_BK_W-1:0];
  assign a_row      = rd_index[IC_IDX_W-1:IC_BK_W];
  assign b_bk       = b_rd_index[IC_BK_W-1:0];
  assign b_row      = b_rd_index[IC_IDX_W-1:IC_BK_W];
  assign next_a_bk  = next_rd_index[IC_BK_W-1:0];
  assign next_a_row = next_rd_index[IC_IDX_W-1:IC_BK_W];
  assign next_b_bk  = next_b_rd_index[IC_BK_W-1:0];
  assign next_b_row = next_b_rd_index[IC_IDX_W-1:IC_BK_W];
  assign fp_bk      = fdip_peek_index[IC_BK_W-1:0];
  assign fp_row     = fdip_peek_index[IC_IDX_W-1:IC_BK_W];
  assign fw_bk      = fdip_w_index[IC_BK_W-1:0];
  assign fw_row     = fdip_w_index[IC_IDX_W-1:IC_BK_W];

  // Single read row per bank: Port A takes its bank, Port B takes its bank in parallel
  logic [IC_BROW_W-1:0] bk_rrow [IC_BANKS], next_bk_rrow [IC_BANKS];
  logic [IC_LINE_W-1:0] bk_rdata [IC_BANKS][IC_WAYS];
  logic [IC_TAG_W-1:0]  bk_rtag  [IC_BANKS][IC_WAYS];
  logic [IC_WAYS-1:0]   bk_rval  [IC_BANKS];

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

  assign eff_w_bk  = eff_w_index[IC_BK_W-1:0];
  assign eff_w_row = eff_w_index[IC_IDX_W-1:IC_BK_W];

  for (genvar bk = 0; bk < IC_BANKS; bk++) begin : g_bank
    assign bk_rrow[bk]      = (rd_en && (a_bk == IC_BK_W'(bk))) ? a_row : b_row;
    assign next_bk_rrow[bk] = (next_a_bk == IC_BK_W'(bk)) ? next_a_row : next_b_row;
    for (genvar w = 0; w < IC_WAYS; w++) begin : g_way
      logic bank_we;
      assign bank_we = eff_we && (eff_w_bk == IC_BK_W'(bk)) && (eff_w_way == IC_WAY_W'(w));

      ttg_sram_1r1w #(
        .DEPTH      (IC_BSETS),
        .WIDTH      (IC_LINE_W),
        .MASK_W     (1),
        .WRITE_FIRST(1'b1),
        .TAG        ("ICACHE_DATA")
      ) u_data_sram (
        .clk  (clk),
        .re   (1'b1),
        .raddr(next_bk_rrow[bk]),
        .rdata(bk_rdata[bk][w]),
        .we   (bank_we),
        .waddr(eff_w_row),
        .wdata(eff_w_line),
        .wmask(1'b1)
      );

      assign bk_rtag[bk][w] = tag_q[bk][w][bk_rrow[bk]];
      assign bk_rval[bk][w] = valid_q[bk][w][bk_rrow[bk]];

      always_ff @(posedge clk) begin
        if (bank_we) begin
          tag_q[bk][w][eff_w_row] <= eff_w_tag;
        end
      end

      always_ff @(posedge clk) begin
        if (!rst_n || inv_all)
          valid_q[bk][w] <= '0;
        else if (bank_we)
          valid_q[bk][w][eff_w_row] <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  logic [IC_BROW_W-1:0] latched_bk_row_q [IC_BANKS];
  always_ff @(posedge clk) begin
    for (int bk = 0; bk < IC_BANKS; bk++) latched_bk_row_q[bk] <= next_bk_rrow[bk];
  end
  assert property (@(posedge clk) disable iff (!rst_n)
    !(cmp_valid && rd_en && hit_any) || (latched_bk_row_q[a_bk] == a_row));
  assert property (@(posedge clk) disable iff (!rst_n)
    !(b_rd_valid && b_hit_any) || (latched_bk_row_q[b_bk] == b_row));
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_next_b_bk;
  assign unused_next_b_bk = ^next_b_bk;
  /* verilator lint_on UNUSEDSIGNAL */
`else
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_next_b_bk;
  assign unused_next_b_bk = ^next_b_bk;
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  for (genvar w = 0; w < IC_WAYS; w++) begin : g_mux
    logic                 b_fwd, b_v;
    logic [IC_TAG_W-1:0]  a_t, b_t;
    logic [IC_LINE_W-1:0] b_d;

    assign way_valid[w] = bk_rval[a_bk][w];
    assign way_line[w]  = bk_rdata[a_bk][w];
    assign a_t          = bk_rtag[a_bk][w];
    assign way_match[w] = way_valid[w] && (a_t == cmp_tag);

    assign b_fwd         = !inv_all && we && (w_index == b_rd_index) && (w_way == IC_WAY_W'(w));
    assign b_v           = inv_all ? 1'b0 : (b_fwd ? 1'b1 : bk_rval[b_bk][w]);
    assign b_t           = b_fwd ? w_tag  : bk_rtag[b_bk][w];
    assign b_d           = b_fwd ? w_line : bk_rdata[b_bk][w];
    assign b_way_line[w] = b_d;
    assign b_way_match[w] = b_v && (b_t == b_cmp_tag);

    assign fp_match[w] = valid_q[fp_bk][w][fp_row] && (tag_q[fp_bk][w][fp_row] == fdip_peek_tag);
    assign ff_match[w] = valid_q[fw_bk][w][fw_row] && (tag_q[fw_bk][w][fw_row] == fdip_w_tag);
    assign ff_inv[w]   = !valid_q[fw_bk][w][fw_row];
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

  // ---- Parallel log-depth SRRIP helpers (IC_WAYS = 8) ----
  function automatic logic [IC_WAY_W-1:0] first_set8_idx(input logic [IC_WAYS-1:0] m);
    logic lo_any;
    logic [1:0] lo_i, hi_i;
    lo_any = |m[3:0];
    lo_i   = m[0] ? 2'd0 : m[1] ? 2'd1 : m[2] ? 2'd2 : 2'd3;
    hi_i   = m[4] ? 2'd0 : m[5] ? 2'd1 : m[6] ? 2'd2 : (m[7] ? 2'd3 : 2'd3);
    return lo_any ? {1'b0, lo_i} : {1'b1, hi_i};
  endfunction

  function automatic logic [IC_WAY_W-1:0] srrip_victim(input logic [IC_RB-1:0] row);
    logic [IC_WAYS-1:0] m3, m2, m1;
    for (int w = 0; w < IC_WAYS; w++) begin
      m3[w] = (row[2 * w +: 2] == 2'd3);
      m2[w] = (row[2 * w +: 2] == 2'd2);
      m1[w] = (row[2 * w +: 2] == 2'd1);
    end
    if (|m3)      return first_set8_idx(m3);
    else if (|m2) return first_set8_idx(m2);
    else if (|m1) return first_set8_idx(m1);
    else          return 3'd0;
  endfunction

  function automatic logic [1:0] max2(input logic [1:0] a, input logic [1:0] b);
    return (a >= b) ? a : b;
  endfunction

  function automatic logic [IC_RB-1:0] srrip_fill_row(input logic [IC_RB-1:0] row, input logic [IC_WAY_W-1:0] wy);
    logic [1:0] m01, m23, m45, m67, m03, m47, mx, delta;
    logic [IC_RB-1:0] nr;
    m01   = max2(row[1:0],   row[3:2]);
    m23   = max2(row[5:4],   row[7:6]);
    m45   = max2(row[9:8],   row[11:10]);
    m67   = max2(row[13:12], row[15:14]);
    m03   = max2(m01, m23);
    m47   = max2(m45, m67);
    mx    = max2(m03, m47);
    delta = ~mx; // 2'd3 - mx
    for (int w = 0; w < IC_WAYS; w++) nr[2 * w +: 2] = row[2 * w +: 2] + delta;
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
