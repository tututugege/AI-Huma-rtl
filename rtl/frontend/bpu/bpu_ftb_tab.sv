// Ref: front-end/BPU/BpuFtb.h  FtbTab / AheadFtbTab (parameterized set-associative FTB array)
`default_nettype none

module bpu_ftb_tab import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int SETS             = 1024,
  parameter int WAYS             = 4,
  parameter int TAG_W            = 14,
  parameter int TGT_BITS         = 0,
  parameter bit ALLOC_ONLY_TAKEN = 1'b0,
  parameter bit AHEAD_MODE       = 1'b0,
  parameter bit HAS_CLR          = 1'b0,
  parameter bit HAS_RD2          = 1'b0,
  parameter bit STORE_B_BASE     = 1'b0
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Lookup read port 0 (S0 for ftb0/aftb/aftb2, S1 Block A for ftb1)
  input  logic [XLEN_BITS-1:0]    rd_base,
  output logic                    rd_hit,
  output ftb_ent_t                rd_ent,
  output ftb_ent_t [WAYS-1:0]     rd_ways,
  output logic [WAYS-1:0][XLEN_BITS-1:0] rd_b_base,
  // Optional lookup read port 1 (Block B for ftb0 / ftb1 when HAS_RD2=1)
  input  logic [XLEN_BITS-1:0]    rd2_base,
  output logic                    rd2_hit,
  output ftb_ent_t                rd2_ent,
  // Single-branch commit RMW update port
  input  logic                    upd_en,
  input  logic [XLEN_BITS-1:0]    upd_base,
  input  logic [XLEN_BITS-1:0]    upd_key_base,
  input  logic [XLEN_BITS-1:0]    upd_b_base,
  input  ftb_br_upd_t             upd_br,
  output logic                    upd_slot_valid,
  output logic [FTB_SLOT_W-1:0]   upd_slot_idx,
  output logic [1:0]              upd_slot_ctr,
  // Predecode false-branch slot clear port (used when HAS_CLR=1)
  input  logic                    clr_en,
  input  logic [XLEN_BITS-1:0]    clr_base,
  input  logic [XLEN_BITS-1:0]    clr_pc
);

  localparam int SET_W    = $clog2(SETS);
  localparam int WAY_W    = $clog2(WAYS);
  localparam int CLR_PORT = 2;
  localparam int RD2_PORT = HAS_CLR ? 3 : 2;
  localparam int N_RD     = 2 + int'(HAS_CLR) + int'(HAS_RD2);
  localparam int N_WR     = HAS_CLR ? 2 : 1;

  typedef ftb_ent_t [WAYS-1:0] set_t;

  function automatic logic [SET_W-1:0] set_idx(input logic [XLEN_BITS-1:0] pc);
    logic [31:0] w;
    w = 32'(pc >> SLOT_SHIFT);
    return SET_W'(w ^ (w >> SET_W));
  endfunction

  function automatic logic [FTB_MAX_TAG_W-1:0] norm_tag(input logic [XLEN_BITS-1:0] pc);
    logic [31:0] w, mask;
    w    = 32'(pc >> SLOT_SHIFT);
    mask = (32'd1 << TAG_W) - 32'd1;
    return FTB_MAX_TAG_W'((w >> SET_W) & mask);
  endfunction

  // ---- Backing array ----
  logic [SET_W-1:0] rd_addr [N_RD];
  set_t             rd_data [N_RD];
  logic             wr_en   [N_WR];
  logic [SET_W-1:0] wr_addr [N_WR];
  set_t             wr_data [N_WR];

  bpu_mem #(
    .W     ($bits(set_t)),
    .DEPTH (SETS),
    .N_RD  (N_RD),
    .N_WR  (N_WR),
    .T     (set_t)
  ) u_mem (
    .clk, .rst_n, .rd_addr, .rd_data, .wr_en, .wr_addr, .wr_data
  );

  // Optional parallel b_base array for 2-Ahead B (STORE_B_BASE=1)
  typedef logic [WAYS-1:0][XLEN_BITS-1:0] bbase_set_t;
  bbase_set_t bbase_rd_upd;
  if (STORE_B_BASE) begin : g_bbase
    logic [SET_W-1:0] bb_ra [2];
    bbase_set_t       bb_rd [2];
    logic             bb_we [1];
    logic [SET_W-1:0] bb_wa [1];
    bbase_set_t       bb_wd [1];
    assign bb_ra[0]     = rd_set0;
    assign bb_ra[1]     = upd_set;
    assign rd_b_base    = bb_rd[0];
    assign bbase_rd_upd = bb_rd[1];
    assign bb_we[0]     = do_upd;
    assign bb_wa[0]     = upd_set;
    always_comb begin
      bb_wd[0]        = bb_rd[1];
      bb_wd[0][sel_w] = upd_b_base;
    end
    bpu_mem #(
      .W     ($bits(bbase_set_t)),
      .DEPTH (SETS),
      .N_RD  (2),
      .N_WR  (1),
      .T     (bbase_set_t)
    ) u_bbase (
      .clk, .rst_n, .rd_addr(bb_ra), .rd_data(bb_rd), .wr_en(bb_we), .wr_addr(bb_wa), .wr_data(bb_wd)
    );
  end else begin : g_nobbase
    assign rd_b_base    = '0;
    assign bbase_rd_upd = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_bb;
    assign unused_bb = ^{upd_b_base, bbase_rd_upd};
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ---- Lookup read ----
  logic [SET_W-1:0]         rd_set0;
  logic [FTB_MAX_TAG_W-1:0] rd_tag_v;

  assign rd_addr[0] = rd_set0;

  always_comb begin
    rd_set0    = set_idx(rd_base);
    rd_ways    = rd_data[0];
    rd_tag_v   = norm_tag(rd_base);
    rd_hit     = 1'b0;
    rd_ent     = '0;
    if (!AHEAD_MODE) begin
      for (int w = 0; w < WAYS; w++) begin
        if (!rd_hit && rd_ways[w].valid && (rd_ways[w].tag == rd_tag_v)) begin
          rd_hit = 1'b1;
          rd_ent = rd_ways[w];
        end
      end
    end
  end

  if (HAS_RD2) begin : g_rd2
    logic [SET_W-1:0]         rd2_set;
    logic [FTB_MAX_TAG_W-1:0] rd2_tag_v;
    assign rd_addr[RD2_PORT] = rd2_set;
    always_comb begin
      rd2_set   = set_idx(rd2_base);
      rd2_tag_v = norm_tag(rd2_base);
      rd2_hit   = 1'b0;
      rd2_ent   = '0;
      for (int w = 0; w < WAYS; w++) begin
        if (!rd2_hit && rd_data[RD2_PORT][w].valid && (rd_data[RD2_PORT][w].tag == rd2_tag_v)) begin
          rd2_hit = 1'b1;
          rd2_ent = rd_data[RD2_PORT][w];
        end
      end
    end
  end else begin : g_nord2
    assign rd2_hit = 1'b0;
    assign rd2_ent = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_rd2;
    assign unused_rd2 = ^rd2_base;
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ---- Update RMW ----
  logic [SET_W-1:0]         upd_set;
  logic [FTB_MAX_TAG_W-1:0] upd_tag;
  logic                     tgt_ok;
  logic                     hit_found, inv_found, do_upd;
  logic [WAY_W-1:0]         hit_w, inv_w, lru_w, sel_w;
  logic [2:0]               max_lru, old_lru;
  ftb_ent_t                 cur_ent;
  ftb_upsert_res_t          up_res;
  set_t                     upd_set_next;
  logic                     any_slot_v;

  assign rd_addr[1] = upd_set;
  assign wr_en[0]   = do_upd;
  assign wr_addr[0] = upd_set;
  assign wr_data[0] = upd_set_next;

  always_comb begin
    upd_set    = AHEAD_MODE ? set_idx(upd_key_base) : set_idx(upd_base);
    upd_tag    = AHEAD_MODE ? FTB_MAX_TAG_W'(ftb_ah_tag(upd_key_base, upd_base, SET_W)) : norm_tag(upd_base);
    tgt_ok     = (TGT_BITS == 0) || !upd_br.actual_dir || (upd_br.br_type == BR_RET) ||
                 ftb_s0_tgt_fits(upd_base, upd_br.target);

    hit_found = 1'b0;
    hit_w     = '0;
    inv_found = 1'b0;
    inv_w     = '0;
    lru_w     = '0;
    max_lru   = rd_data[1][0].lru;
    for (int w = 0; w < WAYS; w++) begin
      if (!hit_found && rd_data[1][w].valid && (rd_data[1][w].tag == upd_tag)) begin
        hit_found = 1'b1;
        hit_w     = WAY_W'(w);
      end
      if (!inv_found && !rd_data[1][w].valid) begin
        inv_found = 1'b1;
        inv_w     = WAY_W'(w);
      end
      if (w > 0 && rd_data[1][w].lru > max_lru) begin
        max_lru = rd_data[1][w].lru;
        lru_w   = WAY_W'(w);
      end
    end

    do_upd = upd_en && tgt_ok && (hit_found || !(ALLOC_ONLY_TAKEN && !upd_br.actual_dir));
    sel_w  = hit_found ? hit_w : (inv_found ? inv_w : lru_w);
    if (hit_found && (!STORE_B_BASE || (bbase_rd_upd[hit_w] == upd_b_base))) begin
      cur_ent = rd_data[1][hit_w];
    end else begin
      cur_ent       = '0;
      cur_ent.valid = 1'b1;
      cur_ent.tag   = upd_tag;
      cur_ent.lru   = hit_found ? rd_data[1][hit_w].lru : 3'(WAYS - 1);
    end
    up_res = ftb_upsert_branch(cur_ent, upd_br);
  end

  always_comb begin
    upd_set_next   = rd_data[1];
    any_slot_v     = 1'b0;
    for (int k = 0; k < FTB_SLOTS; k++) begin
      if (up_res.ent.s[k].valid) any_slot_v = 1'b1;
    end
    old_lru = cur_ent.lru;

    if (do_upd) begin
      upd_set_next[sel_w] = up_res.ent;
      if (!any_slot_v && !AHEAD_MODE) begin
        upd_set_next[sel_w].valid = 1'b0;
      end else begin
        for (int w = 0; w < WAYS; w++) begin
          if (WAY_W'(w) == sel_w) begin
            upd_set_next[w].lru = 3'd0;
          end else if (upd_set_next[w].valid && (upd_set_next[w].lru < old_lru)) begin
            upd_set_next[w].lru = upd_set_next[w].lru + 3'd1;
          end
        end
      end
    end

    upd_slot_valid = do_upd && (any_slot_v || AHEAD_MODE) && up_res.slot_found;
    upd_slot_idx   = up_res.slot_idx;
    upd_slot_ctr   = up_res.slot_ctr;
  end

  // ---- Optional predecode false-branch slot clear (applied after update on same set) ----
  if (HAS_CLR) begin : g_clr
    logic [SET_W-1:0]         clr_set;
    logic [FTB_MAX_TAG_W-1:0] clr_tag;
    logic                     clr_carried, clr_valid_pc, clr_hit;
    logic [3:0]               clr_off;
    set_t                     clr_src, clr_next;
    logic                     slot_any_v;

    assign rd_addr[CLR_PORT] = clr_set;
    assign wr_en[1]          = clr_valid_pc && clr_hit;
    assign wr_addr[1]        = clr_set;
    assign wr_data[1]        = clr_next;

    always_comb begin
      clr_set      = set_idx(clr_base);
      clr_tag      = norm_tag(clr_base);
      clr_carried  = (clr_pc + XLEN_BITS'(SLOT_BYTES) == clr_base);
      clr_valid_pc = clr_en && (clr_carried || (clr_pc >= clr_base));
      clr_off      = clr_carried ? 4'd0 : 4'((clr_pc - clr_base) >> SLOT_SHIFT);
      clr_src      = (do_upd && (upd_set == clr_set)) ? upd_set_next : rd_data[CLR_PORT];
      clr_next     = clr_src;
      clr_hit      = 1'b0;
      slot_any_v   = 1'b0;

      if (clr_valid_pc) begin
        for (int w = 0; w < WAYS; w++) begin
          if (!clr_hit && clr_src[w].valid && (clr_src[w].tag == clr_tag)) begin
            clr_hit    = 1'b1;
            slot_any_v = 1'b0;
            for (int k = 0; k < FTB_SLOTS; k++) begin
              if (clr_src[w].s[k].valid && (clr_src[w].s[k].offset == clr_off)) begin
                clr_next[w].s[k] = '0;
              end else if (clr_src[w].s[k].valid) begin
                slot_any_v = 1'b1;
              end
            end
            if (!slot_any_v) clr_next[w].valid = 1'b0;
          end
        end
      end
    end
  end else begin : g_noclr
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_clr;
    assign unused_clr = ^{clr_en, clr_base, clr_pc};
    /* verilator lint_on UNUSEDSIGNAL */
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_tab;
  assign unused_tab = ^{upd_key_base, upd_br.pred_dir, upd_br.alt_pred, upd_br.pcpn};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
