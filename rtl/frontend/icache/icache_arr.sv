// Ref: front-end/icache/icache_top.cpp  ICacheTop (64KiB 256x4 Lo/Hi 1RW + Even/Odd FF Tag/Valid + SRRIP)
`default_nettype none

module icache_arr import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    rd_en,
  input  logic                    data_rd_en,
  input  logic [IC_IDX_W-1:0]     rd_index,
  input  logic                    rd_pc_hi,
  input  logic                    rd_b_need,
  input  logic                    cmp_valid,
  input  logic [IC_TAG_W-1:0]     cmp_tag,
  output logic                    hit,
  output logic                    b_hit,
  output logic                    has_invalid,
  output logic [IC_WAY_W-1:0]     first_invalid,
  output logic [IC_WAY_W-1:0]     repl_way,
  output logic [IC_LINE_W/2-1:0]  lo_rdata,
  output logic [IC_LINE_W/2-1:0]  hi_rdata,
  input  logic [IC_IDX_W-1:0]     fdip_peek_index,
  input  logic [IC_TAG_W-1:0]     fdip_peek_tag,
  output logic                    fdip_peek_hit,
  input  logic                    we,
  input  logic [IC_IDX_W-1:0]     w_index,
  input  logic [IC_WAY_W-1:0]     w_way,
  input  logic [IC_TAG_W-1:0]     w_tag,
  input  logic [IC_LINE_W-1:0]    w_line,
  input  logic                    inv_all,
  input  logic                    fdip_we,
  input  logic [IC_IDX_W-1:0]     fdip_w_index,
  input  logic [IC_TAG_W-1:0]     fdip_w_tag,
  input  logic [IC_LINE_W-1:0]    fdip_w_line
);

  localparam int HALF_W     = IC_LINE_W / 2;
  localparam int BSETS      = IC_SETS / 2;
  localparam int ROW_W      = IC_IDX_W - 1;
  localparam int DATA_DEPTH = IC_WAYS * IC_SETS;
  localparam int DATA_AW    = IC_WAY_W + IC_IDX_W;

  // Even/Odd 2-bank FF tag & valid arrays (A and A+1 guaranteed opposite banks, zero conflict)
  logic [IC_TAG_W-1:0] tag_q   [2][IC_WAYS][BSETS];
  logic [BSETS-1:0]    valid_q [2][IC_WAYS];
  logic [IC_RB-1:0]    repl_q  [IC_SETS];

  logic [IC_IDX_W-1:0] b_idx;
  logic                a_bk, b_bk, fp_bk, fw_bk, eff_w_bk;
  logic [ROW_W-1:0]    a_row, b_row, fp_row, fw_row, eff_w_row;

  assign b_idx  = rd_index + IC_IDX_W'(1);
  assign a_bk   = rd_index[0];
  assign a_row  = rd_index[IC_IDX_W-1:1];
  assign b_bk   = ~a_bk;
  assign b_row  = b_idx[IC_IDX_W-1:1];
  assign fp_bk  = fdip_peek_index[0];
  assign fp_row = fdip_peek_index[IC_IDX_W-1:1];
  assign fw_bk  = fdip_w_index[0];
  assign fw_row = fdip_w_index[IC_IDX_W-1:1];

  logic [IC_WAYS-1:0] way_valid, way_match, way_invalid, hit_oh, invalid_oh;
  logic [IC_WAYS-1:0] b_way_match, b_hit_oh, fp_match, ff_match, ff_inv, ff_inv_oh;
  logic               hit_any, b_hit_any, invalid_any, ff_hit_any, ff_inv_any;
  logic [IC_WAY_W-1:0] hit_idx, b_hit_idx, first_inv_idx, ff_inv_idx;

  for (genvar w = 0; w < IC_WAYS; w++) begin : g_cmp
    assign way_valid[w]   = valid_q[a_bk][w][a_row];
    assign way_match[w]   = way_valid[w] && (tag_q[a_bk][w][a_row] == cmp_tag);
    assign b_way_match[w] = valid_q[b_bk][w][b_row] && (tag_q[b_bk][w][b_row] == cmp_tag);
    assign fp_match[w]    = valid_q[fp_bk][w][fp_row] && (tag_q[fp_bk][w][fp_row] == fdip_peek_tag);
    assign ff_match[w]    = valid_q[fw_bk][w][fw_row] && (tag_q[fw_bk][w][fw_row] == fdip_w_tag);
    assign ff_inv[w]      = !valid_q[fw_bk][w][fw_row];
  end

  assign way_invalid = ~way_valid;
  ttg_first_set #(.N(IC_WAYS)) u_hit (.req(way_match & {IC_WAYS{cmp_valid && rd_en}}), .onehot(hit_oh), .any(hit_any));
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_hit_idx (.onehot(hit_oh), .idx(hit_idx));

  ttg_first_set #(.N(IC_WAYS)) u_inv (.req(way_invalid), .onehot(invalid_oh), .any(invalid_any));
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_inv_idx (.onehot(invalid_oh), .idx(first_inv_idx));

  ttg_first_set #(.N(IC_WAYS)) u_b_hit (.req(b_way_match), .onehot(b_hit_oh), .any(b_hit_any));
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_b_hit_idx (.onehot(b_hit_oh), .idx(b_hit_idx));

  assign fdip_peek_hit = |fp_match;
  assign ff_hit_any    = |ff_match;
  ttg_first_set #(.N(IC_WAYS)) u_ff_inv (.req(ff_inv), .onehot(ff_inv_oh), .any(ff_inv_any));
  ttg_onehot_to_idx #(.N(IC_WAYS)) u_ff_inv_idx (.onehot(ff_inv_oh), .idx(ff_inv_idx));

  // ---- Parallel 4-way SRRIP helpers (IC_WAYS = 4, IC_RB = 8) ----
  function automatic logic [IC_WAY_W-1:0] first_set4_idx(input logic [IC_WAYS-1:0] m);
    return m[0] ? 2'd0 : m[1] ? 2'd1 : m[2] ? 2'd2 : (m[3] ? 2'd3 : 2'd3);
  endfunction

  function automatic logic [IC_WAY_W-1:0] srrip_victim(input logic [IC_RB-1:0] row);
    logic [IC_WAYS-1:0] m3, m2, m1;
    for (int w = 0; w < IC_WAYS; w++) begin
      m3[w] = (row[2 * w +: 2] == 2'd3);
      m2[w] = (row[2 * w +: 2] == 2'd2);
      m1[w] = (row[2 * w +: 2] == 2'd1);
    end
    if (|m3)      return first_set4_idx(m3);
    else if (|m2) return first_set4_idx(m2);
    else if (|m1) return first_set4_idx(m1);
    else          return 2'd0;
  endfunction

  function automatic logic [1:0] max2(input logic [1:0] a, input logic [1:0] b);
    return (a >= b) ? a : b;
  endfunction

  function automatic logic [IC_RB-1:0] srrip_fill_row(input logic [IC_RB-1:0] row, input logic [IC_WAY_W-1:0] wy);
    logic [1:0] m01, m23, mx, delta;
    logic [IC_RB-1:0] nr;
    m01   = max2(row[1:0], row[3:2]);
    m23   = max2(row[5:4], row[7:6]);
    mx    = max2(m01, m23);
    delta = ~mx;
    for (int w = 0; w < IC_WAYS; w++) nr[2 * w +: 2] = row[2 * w +: 2] + delta;
    nr[2 * wy +: 2] = 2'd2;
    return nr;
  endfunction

  logic                eff_fdip_we, eff_we;
  logic [IC_IDX_W-1:0] eff_w_index;
  logic [IC_WAY_W-1:0] eff_w_way, fdip_repl_way, fdip_w_way;
  logic [IC_TAG_W-1:0] eff_w_tag;
  logic [IC_LINE_W-1:0] eff_w_line;
  logic [IC_RB-1:0]    rrow, wrow, nrow_we, nrow_hit, fdip_rrow, nrow_fdip;

  always_comb begin
    rrow          = repl_q[rd_index];
    repl_way      = srrip_victim(rrow);
    wrow          = repl_q[w_index];
    nrow_we       = srrip_fill_row(wrow, w_way);
    nrow_hit      = rrow;
    nrow_hit[2 * hit_idx +: 2] = 2'd0;

    eff_fdip_we   = fdip_we && !we && !inv_all && !ff_hit_any;
    fdip_rrow     = repl_q[fdip_w_index];
    fdip_repl_way = srrip_victim(fdip_rrow);
    fdip_w_way    = ff_inv_any ? ff_inv_idx : fdip_repl_way;
    nrow_fdip     = srrip_fill_row(fdip_rrow, fdip_w_way);

    eff_we      = we || eff_fdip_we;
    eff_w_index = we ? w_index : fdip_w_index;
    eff_w_way   = we ? w_way   : fdip_w_way;
    eff_w_tag   = we ? w_tag   : fdip_w_tag;
    eff_w_line  = we ? w_line  : fdip_w_line;
    eff_w_bk    = eff_w_index[0];
    eff_w_row   = eff_w_index[IC_IDX_W-1:1];
  end

  // Tag, Valid, and SRRIP sequential storage
  always_ff @(posedge clk) begin
    if (eff_we) tag_q[eff_w_bk][eff_w_way][eff_w_row] <= eff_w_tag;
    if (!rst_n || inv_all) begin
      for (int bk = 0; bk < 2; bk++)
        for (int w = 0; w < IC_WAYS; w++) valid_q[bk][w] <= '0;
    end else if (eff_we) begin
      valid_q[eff_w_bk][eff_w_way][eff_w_row] <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < IC_SETS; i++) repl_q[i] <= '0;
    end else if (we) begin
      repl_q[w_index] <= nrow_we;
    end else if (hit_any) begin
      repl_q[rd_index] <= nrow_hit;
    end else if (eff_fdip_we) begin
      repl_q[fdip_w_index] <= nrow_fdip;
    end
  end

  // Strict single-port 1RW Data SRAMs: Lo-32B and Hi-32B (1024x256b -> 16 x 1024x32 TSMC28 macros)
  logic                lo_en, hi_en;
  logic [DATA_AW-1:0]  lo_addr, hi_addr;
  always_comb begin
    lo_en   = eff_we || (data_rd_en && (!rd_pc_hi || rd_b_need));
    hi_en   = eff_we || data_rd_en;
    lo_addr = eff_we ? {eff_w_way, eff_w_index} : (rd_pc_hi ? {b_hit_idx, b_idx} : {hit_idx, rd_index});
    hi_addr = eff_we ? {eff_w_way, eff_w_index} : {hit_idx, rd_index};
  end

  ttg_sram_1rw #(.DEPTH(DATA_DEPTH), .WIDTH(HALF_W), .MASK_W(1), .TAG("ICACHE_DATA_LO")) u_data_lo (
    .clk(clk), .en(lo_en), .we(eff_we), .addr(lo_addr),
    .wdata(eff_w_line[HALF_W-1:0]), .wmask(1'b1), .rdata(lo_rdata)
  );
  ttg_sram_1rw #(.DEPTH(DATA_DEPTH), .WIDTH(HALF_W), .MASK_W(1), .TAG("ICACHE_DATA_HI")) u_data_hi (
    .clk(clk), .en(hi_en), .we(eff_we), .addr(hi_addr),
    .wdata(eff_w_line[IC_LINE_W-1:HALF_W]), .wmask(1'b1), .rdata(hi_rdata)
  );

`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n) !(we && eff_fdip_we));
  assert property (@(posedge clk) disable iff (!rst_n) !(we && hit_any));
  assert property (@(posedge clk) disable iff (!rst_n) !(eff_fdip_we && hit_any));
  assert property (@(posedge clk) disable iff (!rst_n) !(eff_fdip_we && data_rd_en));
  assert property (@(posedge clk) disable iff (!rst_n) !(we && data_rd_en));
`endif

  assign hit           = hit_any;
  assign b_hit         = b_hit_any && rd_b_need && cmp_valid && rd_en;
  assign has_invalid   = rd_en && invalid_any;
  assign first_invalid = first_inv_idx;

endmodule

`default_nettype wire
