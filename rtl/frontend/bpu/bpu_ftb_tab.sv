// Ref: front-end/BPU/BpuFtb.h  FtbTab / AheadFtbTab (parameterized set-associative FTB array)
// - USE_SRAM=0 (uFTB, 64x4): tiny FF register file for 0-cycle S0 loop; single write port (mutually exclusive T1 upd/clr).
// - USE_SRAM=1 (Main FTB / 1-Ahead FTB / 2-Ahead FTB): strict 1-cycle synchronous `bpu_sram_sync` (1R1W `ttg_sram_1r1w`).
//   Predict reads are launched 1 cycle early; commit training and predecode clear share a single 2-stage (T0->T1) RMW port.
`default_nettype none

module bpu_ftb_tab import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    SETS             = 1024,
  parameter int    WAYS             = 4,
  parameter int    TAG_W            = 14,
  parameter int    TGT_BITS         = 0,
  parameter bit    ALLOC_ONLY_TAKEN = 1'b0,
  parameter bit    AHEAD_MODE       = 1'b0,
  parameter bit    HAS_CLR          = 1'b0,
  parameter bit    HAS_RD2          = 1'b0,
  parameter bit    STORE_B_BASE     = 1'b0,
  parameter bit    USE_SRAM         = 1'b1,
  parameter logic [2:0] RD_WF_MASK  = 3'b010,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG             = "BPU_FTB"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Predict read port 0 (USE_SRAM=0: comb rd_base; USE_SRAM=1: sync launch with rd_en/rd_base, tag-compare with rd_cmp_base)
  input  logic                    rd_en,
  input  logic [XLEN_BITS-1:0]    rd_base,
  input  logic [XLEN_BITS-1:0]    rd_cmp_base,
  output logic                    rd_hit,
  output ftb_ent_t                rd_ent,
  output ftb_ent_t [WAYS-1:0]     rd_ways,
  output logic [WAYS-1:0][XLEN_BITS-1:0] rd_b_base,
  // Optional predict read port 2 (Block B when HAS_RD2=1)
  input  logic                    rd2_en,
  input  logic [XLEN_BITS-1:0]    rd2_base,
  input  logic [XLEN_BITS-1:0]    rd2_cmp_base,
  output logic                    rd2_hit,
  output ftb_ent_t                rd2_ent,
  // T0 sync read launch for commit update & predecode clear (mutually exclusive; unused when USE_SRAM=0)
  input  logic                    t0_upd_en,
  input  logic [XLEN_BITS-1:0]    t0_upd_base,
  input  logic [XLEN_BITS-1:0]    t0_upd_key_base,
  input  logic                    t0_clr_en,
  input  logic [XLEN_BITS-1:0]    t0_clr_base,
  // T1 commit RMW execute & write (mutually exclusive with t1_clr_en)
  input  logic                    t1_upd_en,
  input  logic [XLEN_BITS-1:0]    t1_upd_base,
  input  logic [XLEN_BITS-1:0]    t1_upd_key_base,
  input  logic [XLEN_BITS-1:0]    t1_upd_b_base,
  input  ftb_br_upd_t             t1_upd_br,
  output logic                    upd_slot_valid,
  output logic [FTB_SLOT_W-1:0]   upd_slot_idx,
  output logic [1:0]              upd_slot_ctr,
  // T1 predecode false-branch slot clear execute & write (used when HAS_CLR=1; mutually exclusive with t1_upd_en)
  input  logic                    t1_clr_en,
  input  logic [XLEN_BITS-1:0]    t1_clr_base,
  input  logic [XLEN_BITS-1:0]    t1_clr_pc
);

  localparam int SET_W    = $clog2(SETS);
  localparam int WAY_W    = $clog2(WAYS);
  localparam int N_RD     = HAS_RD2 ? 3 : 2;
  localparam int RD2_PORT = 2;

  typedef ftb_ent_t [WAYS-1:0] set_t;
  typedef logic [WAYS-1:0][XLEN_BITS-1:0] bbase_set_t;

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

  // ---- Backing storage (strict sync 1R1W SRAM when USE_SRAM=1; tiny FF array for S0 uFTB when USE_SRAM=0) ----
  logic             mem_rd_en   [N_RD];
  logic [SET_W-1:0] mem_rd_addr [N_RD];
  set_t             mem_rd_data [N_RD];
  logic             mem_wr_en;
  logic [SET_W-1:0] mem_wr_addr;
  set_t             mem_wr_data;

  logic [SET_W-1:0] rd_set0, t0_rmw_set, t1_upd_set, t1_clr_set;
  logic             do_upd, do_clr;
  logic [WAY_W-1:0] sel_w;
  set_t             upd_set_next, clr_set_next;

  assign rd_set0    = set_idx(rd_base);
  assign t0_rmw_set = t0_upd_en ? (AHEAD_MODE ? set_idx(t0_upd_key_base) : set_idx(t0_upd_base))
                                : set_idx(t0_clr_base);
  assign t1_upd_set = AHEAD_MODE ? set_idx(t1_upd_key_base) : set_idx(t1_upd_base);
  assign t1_clr_set = set_idx(t1_clr_base);

  assign mem_rd_en[0]   = rd_en;
  assign mem_rd_addr[0] = rd_set0;
  assign mem_rd_en[1]   = t0_upd_en || (HAS_CLR && t0_clr_en);
  assign mem_rd_addr[1] = t0_rmw_set;

  assign mem_wr_en   = do_upd || (HAS_CLR && do_clr);
  assign mem_wr_addr = do_upd ? t1_upd_set : t1_clr_set;
  assign mem_wr_data = do_upd ? upd_set_next : clr_set_next;

  if (USE_SRAM) begin : g_sram
    bpu_sram_sync #(
      .W      ($bits(set_t)),
      .DEPTH  (SETS),
      .N_RD   (N_RD),
      .T      (set_t),
      .WF_MASK(RD_WF_MASK[N_RD-1:0]),
      .TAG    (TAG)
    ) u_mem (
      .clk    (clk),
      .rd_en  (mem_rd_en),
      .rd_addr(mem_rd_addr),
      .rd_data(mem_rd_data),
      .wr_en  (mem_wr_en),
      .wr_addr(mem_wr_addr),
      .wr_data(mem_wr_data)
    );
  end else begin : g_ff_uftb
    set_t ff_mem_q [SETS];
`ifndef SYNTHESIS
    initial begin
      for (int i = 0; i < SETS; i++) ff_mem_q[i] = '0;
    end
`endif
    always_ff @(posedge clk) begin
      if (mem_wr_en) ff_mem_q[mem_wr_addr] <= mem_wr_data;
    end
    always_comb begin
      mem_rd_data[0] = ff_mem_q[rd_set0];
      mem_rd_data[1] = ff_mem_q[t1_upd_en ? t1_upd_set : t1_clr_set];
    end
    if (HAS_RD2) begin : g_ff_rd2
      assign mem_rd_data[RD2_PORT] = ff_mem_q[mem_rd_addr[RD2_PORT]];
    end
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_ff_re;
    assign unused_ff_re = ^{mem_rd_en[0], mem_rd_en[1], rd2_en};
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // Optional parallel b_base array for 2-Ahead B (STORE_B_BASE=1, always USE_SRAM=1)
  bbase_set_t bbase_rd_upd;
  if (STORE_B_BASE) begin : g_bbase
    logic             bb_re [2];
    logic [SET_W-1:0] bb_ra [2];
    bbase_set_t       bb_rd [2];
    bbase_set_t       bb_wd;
    assign bb_re[0]     = rd_en;
    assign bb_ra[0]     = rd_set0;
    assign bb_re[1]     = t0_upd_en;
    assign bb_ra[1]     = t0_rmw_set;
    assign rd_b_base    = bb_rd[0];
    assign bbase_rd_upd = bb_rd[1];
    always_comb begin
      bb_wd        = bb_rd[1];
      bb_wd[sel_w] = t1_upd_b_base;
    end
    bpu_sram_sync #(
      .W      ($bits(bbase_set_t)),
      .DEPTH  (SETS),
      .N_RD   (2),
      .T      (bbase_set_t),
      .WF_MASK(2'b10),
      .TAG    ("BPU_AFTB2_BBASE")
    ) u_bbase (
      .clk    (clk),
      .rd_en  (bb_re),
      .rd_addr(bb_ra),
      .rd_data(bb_rd),
      .wr_en  (do_upd),
      .wr_addr(t1_upd_set),
      .wr_data(bb_wd)
    );
  end else begin : g_nobbase
    assign rd_b_base    = '0;
    assign bbase_rd_upd = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_bb;
    assign unused_bb = ^{t1_upd_b_base, bbase_rd_upd};
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ---- Lookup read port 0 (tag compare uses rd_cmp_base when USE_SRAM=1, rd_base when USE_SRAM=0) ----
  logic [FTB_MAX_TAG_W-1:0] rd_tag_v;

  always_comb begin
    rd_ways  = mem_rd_data[0];
    rd_tag_v = norm_tag(USE_SRAM ? rd_cmp_base : rd_base);
    rd_hit   = 1'b0;
    rd_ent   = '0;
    if (!AHEAD_MODE) begin
      for (int w = 0; w < WAYS; w++) begin
        if (!rd_hit && rd_ways[w].valid && (rd_ways[w].tag == rd_tag_v)) begin
          rd_hit = 1'b1;
          rd_ent = rd_ways[w];
        end
      end
    end
  end

  // ---- Optional lookup read port 2 (Block B) ----
  if (HAS_RD2) begin : g_rd2
    logic [FTB_MAX_TAG_W-1:0] rd2_tag_v;
    assign mem_rd_en[RD2_PORT]   = rd2_en;
    assign mem_rd_addr[RD2_PORT] = set_idx(rd2_base);
    always_comb begin
      rd2_tag_v = norm_tag(USE_SRAM ? rd2_cmp_base : rd2_base);
      rd2_hit   = 1'b0;
      rd2_ent   = '0;
      for (int w = 0; w < WAYS; w++) begin
        if (!rd2_hit && mem_rd_data[RD2_PORT][w].valid && (mem_rd_data[RD2_PORT][w].tag == rd2_tag_v)) begin
          rd2_hit = 1'b1;
          rd2_ent = mem_rd_data[RD2_PORT][w];
        end
      end
    end
  end else begin : g_nord2
    assign rd2_hit = 1'b0;
    assign rd2_ent = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_rd2;
    assign unused_rd2 = ^{rd2_en, rd2_base, rd2_cmp_base};
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ---- T1 Update RMW (using mem_rd_data[1]) ----
  logic [FTB_MAX_TAG_W-1:0] upd_tag;
  logic                     tgt_ok;
  logic                     hit_found, inv_found;
  logic [WAY_W-1:0]         hit_w, inv_w, lru_w;
  logic [2:0]               max_lru, old_lru;
  ftb_ent_t                 cur_ent;
  ftb_upsert_res_t          up_res;
  logic                     any_slot_v;

  always_comb begin
    upd_tag = AHEAD_MODE ? FTB_MAX_TAG_W'(ftb_ah_tag(t1_upd_key_base, t1_upd_base, SET_W)) : norm_tag(t1_upd_base);
    tgt_ok  = (TGT_BITS == 0) || !t1_upd_br.actual_dir || (t1_upd_br.br_type == BR_RET) ||
              ftb_s0_tgt_fits(t1_upd_base, t1_upd_br.target);

    hit_found = 1'b0;
    hit_w     = '0;
    inv_found = 1'b0;
    inv_w     = '0;
    lru_w     = '0;
    max_lru   = mem_rd_data[1][0].lru;
    for (int w = 0; w < WAYS; w++) begin
      if (!hit_found && mem_rd_data[1][w].valid && (mem_rd_data[1][w].tag == upd_tag)) begin
        hit_found = 1'b1;
        hit_w     = WAY_W'(w);
      end
      if (!inv_found && !mem_rd_data[1][w].valid) begin
        inv_found = 1'b1;
        inv_w     = WAY_W'(w);
      end
      if (w > 0 && mem_rd_data[1][w].lru > max_lru) begin
        max_lru = mem_rd_data[1][w].lru;
        lru_w   = WAY_W'(w);
      end
    end

    do_upd = t1_upd_en && tgt_ok && (hit_found || !(ALLOC_ONLY_TAKEN && !t1_upd_br.actual_dir));
    sel_w  = hit_found ? hit_w : (inv_found ? inv_w : lru_w);
    if (hit_found && (!STORE_B_BASE || (bbase_rd_upd[hit_w] == t1_upd_b_base))) begin
      cur_ent = mem_rd_data[1][hit_w];
    end else begin
      cur_ent       = '0;
      cur_ent.valid = 1'b1;
      cur_ent.tag   = upd_tag;
      cur_ent.lru   = hit_found ? mem_rd_data[1][hit_w].lru : 3'(WAYS - 1);
    end
    up_res = ftb_upsert_branch(cur_ent, t1_upd_br);
  end

  always_comb begin
    upd_set_next = mem_rd_data[1];
    any_slot_v   = 1'b0;
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

  // ---- T1 Predecode false-branch slot clear RMW (mutually exclusive with t1_upd_en, shares mem_rd_data[1] & 1W) ----
  if (HAS_CLR) begin : g_clr
    logic [FTB_MAX_TAG_W-1:0] clr_tag;
    logic                     clr_carried, clr_valid_pc, clr_hit;
    logic [3:0]               clr_off;
    logic                     slot_any_v;

    always_comb begin
      clr_tag      = norm_tag(t1_clr_base);
      clr_carried  = (t1_clr_pc + XLEN_BITS'(SLOT_BYTES) == t1_clr_base);
      clr_valid_pc = t1_clr_en && !t1_upd_en && (clr_carried || (t1_clr_pc >= t1_clr_base));
      clr_off      = clr_carried ? 4'd0 : 4'((t1_clr_pc - t1_clr_base) >> SLOT_SHIFT);
      clr_set_next = mem_rd_data[1];
      clr_hit      = 1'b0;
      slot_any_v   = 1'b0;

      if (clr_valid_pc) begin
        for (int w = 0; w < WAYS; w++) begin
          if (!clr_hit && mem_rd_data[1][w].valid && (mem_rd_data[1][w].tag == clr_tag)) begin
            clr_hit    = 1'b1;
            slot_any_v = 1'b0;
            for (int k = 0; k < FTB_SLOTS; k++) begin
              if (mem_rd_data[1][w].s[k].valid && (mem_rd_data[1][w].s[k].offset == clr_off)) begin
                clr_set_next[w].s[k] = '0;
              end else if (mem_rd_data[1][w].s[k].valid) begin
                slot_any_v = 1'b1;
              end
            end
            if (!slot_any_v) clr_set_next[w].valid = 1'b0;
          end
        end
      end
      do_clr = clr_valid_pc && clr_hit;
    end
  end else begin : g_noclr
    assign do_clr       = 1'b0;
    assign clr_set_next = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_clr;
    assign unused_clr = ^{t0_clr_en, t0_clr_base, t1_clr_en, t1_clr_base, t1_clr_pc};
    /* verilator lint_on UNUSEDSIGNAL */
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_tab;
  assign unused_tab = ^{rst_n, rd_cmp_base, t0_upd_base, t0_upd_key_base, t1_upd_key_base,
                        t1_upd_br.pred_dir, t1_upd_br.alt_pred, t1_upd_br.pcpn};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
