// Ref: front-end/BPU/BpuFtb.h  FtbTab / AheadFtbTab (v10: Zero-T0-Read Meta + WRBypass + PLRU + 1-entry WrBuf)
// - USE_SRAM=0 (uFTB, 16x4=64 FF): tiny FF register file for 0-cycle S0 fallback.
// - USE_SRAM=1 (Main FTB 4B / 1-Ahead FTB 2B / 2-Ahead FTB 2B):
//     * Single-port 1RW `bpu_sram_1rw_banked` with MASK_W = WAYS (single-way write, ZERO multi-way RMW!)
//     * Commit uses ftb_rec Meta + 8-entry FF WRBypass + per-set tree-PLRU -> ZERO T0 SRAM reads!
//     * Predict ALWAYS wins FTB 1RW banks; blocked commit writes hold in 1-entry FtbWrBuf!
`default_nettype none

module bpu_ftb_tab import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    SETS             = 1024,
  parameter int    WAYS             = 4,
  parameter int    NB               = BPU_FTB1_BANKS,
  parameter int    TAG_W            = 14,
  parameter int    TGT_BITS         = 0,
  parameter bit    ALLOC_ONLY_TAKEN = 1'b0,
  parameter bit    AHEAD_MODE       = 1'b0,
  parameter bit    HAS_CLR          = 1'b0,
  parameter bit    HAS_RD2          = 1'b0,
  parameter bit    STORE_B_BASE     = 1'b0,
  parameter bit    USE_SRAM         = 1'b1,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG             = "BPU_FTB"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Predict read port 0 (USE_SRAM=0: comb rd_base; USE_SRAM=1: 1RW sync launch with rd_en/rd_base)
  input  logic                    rd_en,
  input  logic [XLEN_BITS-1:0]    rd_base,
  input  logic [XLEN_BITS-1:0]    rd_cmp_base,
  output logic                    rd_hit,
  output logic [$clog2(WAYS)-1:0] rd_way,
  output ftb_ent_t                rd_ent,
  output ftb_ent_t [WAYS-1:0]     rd_ways,
  output logic [WAYS-1:0][FTB_VA_BITS-1:0] rd_b_base,
  // Optional predict read port 2 (Block B when HAS_RD2=1; guaranteed different bank from port 0)
  input  logic                    rd2_en,
  input  logic [XLEN_BITS-1:0]    rd2_base,
  input  logic [XLEN_BITS-1:0]    rd2_cmp_base,
  output logic                    rd2_hit,
  output logic [$clog2(WAYS)-1:0] rd2_way,
  output ftb_ent_t                rd2_ent,
  // Single-cycle pure commit update (from ftb_rec Meta + WRBypass + PLRU; ZERO T0 read!)
  input  logic                    upd_en,
  input  logic [XLEN_BITS-1:0]    upd_base,
  input  logic [XLEN_BITS-1:0]    upd_key_base,
  input  logic [XLEN_BITS-1:0]    upd_b_base,
  input  ftb_br_upd_t             upd_br,
  input  logic                    upd_meta_hit,
  input  logic [$clog2(WAYS)-1:0] upd_meta_way,
  input  ftb_ent_t                upd_meta_ent,
  input  logic [NB-1:0]           rd_bank_mask,   // Predict read banks busy this cycle (Predict ALWAYS wins!)
  output logic                    upd_slot_valid,
  output logic [FTB_SLOT_W-1:0]   upd_slot_idx,
  output logic [1:0]              upd_slot_ctr,
  output logic                    upd_any_v,
  // Rare predecode false-branch slot clear (USE_SRAM=0: 1-cycle FF; USE_SRAM=1: 2-cycle idle bank RMW)
  input  logic                    clr_en,
  input  logic [XLEN_BITS-1:0]    clr_base,
  input  logic [XLEN_BITS-1:0]    clr_pc
);

  localparam int SET_W    = $clog2(SETS);
  localparam int WAY_W    = $clog2(WAYS);
  localparam int BK_W     = (NB > 1) ? $clog2(NB) : 1;

  typedef ftb_ent_t [WAYS-1:0] set_t;
  typedef logic [WAYS-1:0][FTB_VA_BITS-1:0] bbase_set_t;
  localparam int ENT_BITS = $bits(ftb_ent_t);
  localparam int SET_BITS = $bits(set_t);
  localparam int BB_BITS  = $bits(bbase_set_t);

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

  logic [SET_W-1:0] rd_set0, rd_set1;
  assign rd_set0 = set_idx(rd_base);
  assign rd_set1 = set_idx(rd2_base);

  if (!USE_SRAM) begin : g_ff_uftb
    // ---- Tiny 16x4=64-entry FF uFTB (0-cycle comb read, 1-cycle commit update & clear) ----
    set_t ff_mem_q [SETS];
    logic [SET_W-1:0]         upd_s, clr_s;
    logic [FTB_MAX_TAG_W-1:0] upd_tg, clr_tg;
    logic                     tgt_ok, hit_found, inv_found, do_upd, do_clr;
    logic [WAY_W-1:0]         hit_w, inv_w, sel_w, plru_vic;
    ftb_ent_t                 cur_ent;
    ftb_upsert_res_t          up_res;
    set_t                     upd_set_next, clr_set_next;
    logic                     any_slot_v;

    assign upd_s  = set_idx(upd_base);
    assign clr_s  = set_idx(clr_base);
    assign upd_tg = norm_tag(upd_base);
    assign clr_tg = norm_tag(clr_base);

    bpu_plru #(.SETS(SETS), .WAYS(WAYS)) u_plru (
      .clk, .rst_n,
      .rd_set    (upd_s),
      .victim_way(plru_vic),
      .touch_en  (do_upd && any_slot_v),
      .touch_set (upd_s),
      .touch_way (sel_w)
    );

    always_comb begin
      set_t s_cur;
      s_cur     = ff_mem_q[upd_s];
      tgt_ok    = (TGT_BITS == 0) || !upd_br.actual_dir || (upd_br.br_type == BR_RET) ||
                  ftb_s0_tgt_fits(upd_base, upd_br.target);
      hit_found = 1'b0; hit_w = '0;
      inv_found = 1'b0; inv_w = '0;
      for (int w = 0; w < WAYS; w++) begin
        if (!hit_found && s_cur[w].valid && (s_cur[w].tag == upd_tg)) begin
          hit_found = 1'b1; hit_w = WAY_W'(w);
        end
        if (!inv_found && !s_cur[w].valid) begin
          inv_found = 1'b1; inv_w = WAY_W'(w);
        end
      end
      do_upd = upd_en && tgt_ok && (hit_found || !(ALLOC_ONLY_TAKEN && !upd_br.actual_dir));
      sel_w  = hit_found ? hit_w : (inv_found ? inv_w : plru_vic);
      if (hit_found) begin
        cur_ent = s_cur[hit_w];
      end else begin
        cur_ent       = '0;
        cur_ent.valid = 1'b1;
        cur_ent.tag   = upd_tg;
      end
      up_res = ftb_upsert_branch(cur_ent, upd_br);
      any_slot_v = 1'b0;
      for (int k = 0; k < FTB_SLOTS; k++) if (up_res.ent.s[k].valid) any_slot_v = 1'b1;

      upd_set_next = s_cur;
      if (do_upd) begin
        upd_set_next[sel_w] = up_res.ent;
        if (!any_slot_v) upd_set_next[sel_w].valid = 1'b0;
      end

      // Predecode clear
      clr_set_next = ff_mem_q[clr_s];
      do_clr       = 1'b0;
      begin
        logic clr_car, clr_vok, c_hit, s_any;
        logic [3:0] clr_off;
        clr_car = (clr_pc + XLEN_BITS'(SLOT_BYTES) == clr_base);
        clr_vok = clr_car || (clr_pc >= clr_base);
        clr_off = clr_car ? 4'd0 : 4'((clr_pc - clr_base) >> SLOT_SHIFT);
        c_hit   = 1'b0;
        s_any   = 1'b0;
        if (HAS_CLR && clr_en && clr_vok) begin
          for (int w = 0; w < WAYS; w++) begin
            if (!c_hit && clr_set_next[w].valid && (clr_set_next[w].tag == clr_tg)) begin
              c_hit = 1'b1;
              s_any = 1'b0;
              for (int k = 0; k < FTB_SLOTS; k++) begin
                if (clr_set_next[w].s[k].valid && (clr_set_next[w].s[k].offset == clr_off))
                  clr_set_next[w].s[k] = '0;
                else if (clr_set_next[w].s[k].valid)
                  s_any = 1'b1;
              end
              if (!s_any) clr_set_next[w].valid = 1'b0;
            end
          end
        end
        do_clr = HAS_CLR && clr_en && c_hit;
      end

      upd_slot_valid = do_upd && any_slot_v && up_res.slot_found;
      upd_slot_idx   = up_res.slot_idx;
      upd_slot_ctr   = up_res.slot_ctr;
      upd_any_v      = any_slot_v;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int i = 0; i < SETS; i++) ff_mem_q[i] <= '0;
      end else begin
        if (do_upd) ff_mem_q[upd_s] <= upd_set_next;
        if (do_clr) ff_mem_q[clr_s] <= clr_set_next;
      end
    end

    // Comb lookup port 0 & optional port 2
    always_comb begin
      logic [FTB_MAX_TAG_W-1:0] t0, t2;
      rd_ways   = ff_mem_q[rd_set0];
      rd_b_base = '0;
      t0        = norm_tag(rd_base);
      rd_hit    = 1'b0;
      rd_way    = '0;
      rd_ent    = '0;
      for (int w = 0; w < WAYS; w++) begin
        if (!rd_hit && rd_ways[w].valid && (rd_ways[w].tag == t0)) begin
          rd_hit = 1'b1; rd_way = WAY_W'(w); rd_ent = rd_ways[w];
        end
      end
      rd2_hit = 1'b0; rd2_way = '0; rd2_ent = '0;
      if (HAS_RD2) begin
        set_t s2;
        s2 = ff_mem_q[rd_set1];
        t2 = norm_tag(rd2_base);
        for (int w = 0; w < WAYS; w++) begin
          if (!rd2_hit && s2[w].valid && (s2[w].tag == t2)) begin
            rd2_hit = 1'b1; rd2_way = WAY_W'(w); rd2_ent = s2[w];
          end
        end
      end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_ff;
    assign unused_ff = ^{rd_en, rd_cmp_base, rd2_en, rd2_cmp_base, upd_key_base, upd_b_base,
                         upd_meta_hit, upd_meta_way, upd_meta_ent, rd_bank_mask};
    /* verilator lint_on UNUSEDSIGNAL */

  end else begin : g_sram_ftb
    // ---- Multi-Bank 1RW SRAM FTB (Zero T0 Read: Meta + WRBypass + PLRU + 1-entry FtbWrBuf!) ----
    localparam int WRB_KEY_W  = SET_W + TAG_W;
    localparam int WRB_DATA_W = WAY_W + ENT_BITS + (STORE_B_BASE ? FTB_VA_BITS : 0);

    logic [SET_W-1:0]         upd_s;
    logic [FTB_MAX_TAG_W-1:0] upd_tg;
    logic [FTB_VA_BITS-1:0]   upd_b38;
    logic [WAY_W-1:0]         plru_vic, sel_way;
    logic                     wrb_hit;
    logic [WRB_DATA_W-1:0]    wrb_rd_data, wrb_wr_data;
    logic                     wrb_wr_en;
    logic [WRB_KEY_W-1:0]     wrb_rd_key, wrb_wr_key;

    assign upd_s   = AHEAD_MODE ? set_idx(upd_key_base) : set_idx(upd_base);
    assign upd_tg  = AHEAD_MODE ? FTB_MAX_TAG_W'(ftb_ah_tag(upd_key_base, upd_base, SET_W)) : norm_tag(upd_base);
    assign upd_b38 = sv39_pack(upd_b_base);

    // 1. Per-set tree-PLRU FF array
    logic new_ftb_wr;
    bpu_plru #(.SETS(SETS), .WAYS(WAYS)) u_plru (
      .clk, .rst_n,
      .rd_set    (upd_s),
      .victim_way(plru_vic),
      .touch_en  (new_ftb_wr),
      .touch_set (upd_s),
      .touch_way (sel_way)
    );

    // 2. 8-entry FF WRBypass CAM+Mem
    assign wrb_rd_key = {upd_s, upd_tg[TAG_W-1:0]};
    bpu_wrbypass #(.N(BPU_WRB_N), .KEY_W(WRB_KEY_W), .DATA_W(WRB_DATA_W)) u_wrb (
      .clk, .rst_n,
      .rd_key (wrb_rd_key),
      .rd_hit (wrb_hit),
      .rd_data(wrb_rd_data),
      .wr_en  (wrb_wr_en),
      .wr_key (wrb_wr_key),
      .wr_data(wrb_wr_data)
    );

    // 3. Commit plan from Meta + WRBypass + commit-time PLRU victim
    logic [WAY_W-1:0]       wrb_way;
    ftb_ent_t               wrb_ent;
    logic [FTB_VA_BITS-1:0] wrb_b38;
    ftb_ent_t               old_ent, cur_ent, new_ent;
    ftb_upsert_res_t        up_res;
    logic                   had_hit, any_slot_v;

    if (STORE_B_BASE) begin : g_wrb_unp_bb
      assign {wrb_way, wrb_ent, wrb_b38} = wrb_rd_data;
    end else begin : g_wrb_unp_nobb
      assign {wrb_way, wrb_ent} = wrb_rd_data;
      assign wrb_b38            = '0;
    end

    always_comb begin
      had_hit = 1'b0;
      old_ent = '0;
      sel_way = plru_vic;
      if (wrb_hit) begin
        had_hit = wrb_ent.valid && (wrb_ent.tag == upd_tg) && (!STORE_B_BASE || (wrb_b38 == upd_b38));
        old_ent = wrb_ent;
        sel_way = wrb_way;
      end else if (upd_meta_hit) begin
        had_hit = 1'b1;
        old_ent = upd_meta_ent;
        sel_way = upd_meta_way;
      end

      if (had_hit) begin
        cur_ent = old_ent;
      end else begin
        cur_ent       = '0;
        cur_ent.valid = 1'b1;
        cur_ent.tag   = upd_tg;
      end

      up_res     = ftb_upsert_branch(cur_ent, upd_br);
      new_ent    = up_res.ent;
      any_slot_v = 1'b0;
      for (int k = 0; k < FTB_SLOTS; k++) if (new_ent.s[k].valid) any_slot_v = 1'b1;
      if (!any_slot_v && !AHEAD_MODE) new_ent.valid = 1'b0;

      new_ftb_wr     = upd_en && (any_slot_v || AHEAD_MODE) && (!had_hit || !ftb_ent_payload_eq(new_ent, old_ent));
      upd_slot_valid = upd_en && (any_slot_v || AHEAD_MODE) && up_res.slot_found;
      upd_slot_idx   = up_res.slot_idx;
      upd_slot_ctr   = up_res.slot_ctr;
      upd_any_v      = any_slot_v;
    end

    // 4. 1-entry FtbWrBuf (Predict ALWAYS wins 1RW FTB banks; buffered write drains on next free bank cycle!)
    logic                   wb_v_q, wb_v_d;
    logic [SET_W-1:0]       wb_s_q, wb_s_d;
    logic [WAY_W-1:0]       wb_w_q, wb_w_d;
    ftb_ent_t               wb_e_q, wb_e_d;
    logic [FTB_VA_BITS-1:0] wb_b_q, wb_b_d;

    logic                   do_ftb_wr;
    logic [SET_W-1:0]       wr_set;
    logic [WAY_W-1:0]       wr_way;
    ftb_ent_t               wr_ent;
    logic [FTB_VA_BITS-1:0] wr_b38;
    logic [NB-1:0]          busy_after_wr;

    always_comb begin
      logic [BK_W-1:0] obk, nbk;
      obk           = (NB > 1) ? wb_s_q[BK_W-1:0] : BK_W'(0);
      nbk           = (NB > 1) ? upd_s[BK_W-1:0]  : BK_W'(0);
      do_ftb_wr     = 1'b0;
      wr_set        = upd_s;
      wr_way        = sel_way;
      wr_ent        = new_ent;
      wr_b38        = upd_b38;
      wb_v_d        = 1'b0;
      wb_s_d        = wb_s_q;
      wb_w_d        = wb_w_q;
      wb_e_d        = wb_e_q;
      wb_b_d        = wb_b_q;
      busy_after_wr = rd_bank_mask;

      if (wb_v_q) begin
        if (!rd_bank_mask[obk]) begin
          do_ftb_wr          = 1'b1;
          wr_set             = wb_s_q;
          wr_way             = wb_w_q;
          wr_ent             = wb_e_q;
          wr_b38             = wb_b_q;
          busy_after_wr[obk] = 1'b1;
          if (new_ftb_wr) begin
            wb_v_d = 1'b1; wb_s_d = upd_s; wb_w_d = sel_way; wb_e_d = new_ent; wb_b_d = upd_b38;
          end
        end else begin
          wb_v_d = 1'b1;
          if (new_ftb_wr) begin
            wb_s_d = upd_s; wb_w_d = sel_way; wb_e_d = new_ent; wb_b_d = upd_b38;
          end
        end
      end else if (new_ftb_wr) begin
        if (!rd_bank_mask[nbk]) begin
          do_ftb_wr          = 1'b1;
          wr_set             = upd_s;
          wr_way             = sel_way;
          wr_ent             = new_ent;
          wr_b38             = upd_b38;
          busy_after_wr[nbk] = 1'b1;
        end else begin
          wb_v_d = 1'b1; wb_s_d = upd_s; wb_w_d = sel_way; wb_e_d = new_ent; wb_b_d = upd_b38;
        end
      end
    end

    // 5. Optional rare predecode clear (ONLY HAS_CLR=1, i.e. u_ftb1): 2-cycle idle-bank read -> single-way write
    logic                   clr_rd_fire, clr_wr_fire;
    logic [SET_W-1:0]       clr_rd_set, clr_wr_set;
    logic [WAY_W-1:0]       clr_wr_way;
    ftb_ent_t               clr_wr_ent;
    logic [SET_BITS-1:0]    raw_clr_rd;
    logic                   clr_wrb_ins;
    logic [TAG_W-1:0]       clr_wrb_tg;

    if (HAS_CLR) begin : g_clr_sram
      logic                   clr_pend_v_q, clr_pend_v_d;
      logic [XLEN_BITS-1:0]   clr_pend_base_q, clr_pend_base_d, clr_pend_pc_q, clr_pend_pc_d;
      logic                   clr_t1_v_q, clr_t1_v_d;
      logic [XLEN_BITS-1:0]   clr_t1_base_q, clr_t1_pc_q;
      logic                   clr_hold_valid_q;
      set_t                   clr_hold_set_q;
      logic                   clr_rd_fire_q;
      set_t                   clr_set_eff;

      always_comb begin
        logic [XLEN_BITS-1:0] cbase;
        logic [SET_W-1:0]     cset;
        logic [BK_W-1:0]      cbk, t1bk;
        logic                 clr_consumed, c_hit, s_any, clr_car, clr_vok;
        logic [3:0]           clr_off;
        logic [FTB_MAX_TAG_W-1:0] t1_tg;
        ftb_ent_t             c_ent;

        clr_set_eff = clr_rd_fire_q ? set_t'(raw_clr_rd) : clr_hold_set_q;
        t1_tg       = norm_tag(clr_t1_base_q);
        clr_wr_set  = set_idx(clr_t1_base_q);
        t1bk        = (NB > 1) ? clr_wr_set[BK_W-1:0] : BK_W'(0);
        clr_car     = (clr_t1_pc_q + XLEN_BITS'(SLOT_BYTES) == clr_t1_base_q);
        clr_vok     = clr_car || (clr_t1_pc_q >= clr_t1_base_q);
        clr_off     = clr_car ? 4'd0 : 4'((clr_t1_pc_q - clr_t1_base_q) >> SLOT_SHIFT);

        c_hit      = 1'b0;
        s_any      = 1'b0;
        c_ent      = '0;
        clr_wr_way = '0;
        clr_wr_ent = '0;
        if (clr_t1_v_q && clr_vok) begin
          for (int w = 0; w < WAYS; w++) begin
            if (!c_hit && clr_set_eff[w].valid && (clr_set_eff[w].tag == t1_tg)) begin
              c_hit      = 1'b1;
              clr_wr_way = WAY_W'(w);
              c_ent      = clr_set_eff[w];
              s_any      = 1'b0;
              for (int k = 0; k < FTB_SLOTS; k++) begin
                if (c_ent.s[k].valid && (c_ent.s[k].offset == clr_off)) c_ent.s[k] = '0;
                else if (c_ent.s[k].valid) s_any = 1'b1;
              end
              if (!s_any) c_ent.valid = 1'b0;
              clr_wr_ent = c_ent;
            end
          end
        end

        clr_wr_fire  = clr_t1_v_q && !do_ftb_wr && !busy_after_wr[t1bk] && c_hit;
        clr_wrb_ins  = clr_wr_fire;
        clr_wrb_tg   = t1_tg[TAG_W-1:0];

        clr_t1_v_d   = clr_t1_v_q && c_hit && !clr_wr_fire;
        clr_rd_fire  = 1'b0;
        clr_consumed = 1'b0;
        cbase        = clr_pend_v_q ? clr_pend_base_q : clr_base;
        cset         = set_idx(cbase);
        cbk          = (NB > 1) ? cset[BK_W-1:0] : BK_W'(0);
        clr_rd_set   = cset;

        if (!clr_t1_v_d && (clr_pend_v_q || clr_en)) begin
          if (!busy_after_wr[cbk] && !(clr_wr_fire && (cbk == t1bk))) begin
            clr_rd_fire  = 1'b1;
            clr_t1_v_d   = 1'b1;
            clr_consumed = 1'b1;
          end
        end

        clr_pend_v_d    = 1'b0;
        clr_pend_base_d = clr_pend_base_q;
        clr_pend_pc_d   = clr_pend_pc_q;
        if (clr_en && !(clr_consumed && !clr_pend_v_q)) begin
          clr_pend_v_d    = 1'b1;
          clr_pend_base_d = clr_base;
          clr_pend_pc_d   = clr_pc;
        end else if (clr_pend_v_q && !clr_consumed) begin
          clr_pend_v_d    = 1'b1;
          clr_pend_base_d = clr_pend_base_q;
          clr_pend_pc_d   = clr_pend_pc_q;
        end
      end

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          clr_pend_v_q     <= 1'b0;
          clr_pend_base_q  <= '0;
          clr_pend_pc_q    <= '0;
          clr_t1_v_q       <= 1'b0;
          clr_t1_base_q    <= '0;
          clr_t1_pc_q      <= '0;
          clr_rd_fire_q    <= 1'b0;
          clr_hold_valid_q <= 1'b0;
          clr_hold_set_q   <= '0;
        end else begin
          clr_pend_v_q    <= clr_pend_v_d;
          clr_pend_base_q <= clr_pend_base_d;
          clr_pend_pc_q   <= clr_pend_pc_d;
          clr_t1_v_q      <= clr_t1_v_d;
          clr_rd_fire_q   <= clr_rd_fire;
          if (clr_rd_fire) begin
            clr_t1_base_q <= clr_pend_v_q ? clr_pend_base_q : clr_base;
            clr_t1_pc_q   <= clr_pend_v_q ? clr_pend_pc_q   : clr_pc;
          end
          if (clr_rd_fire_q) begin
            clr_hold_set_q   <= set_t'(raw_clr_rd);
            clr_hold_valid_q <= 1'b1;
          end
        end
      end
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_clr_hv;
      assign unused_clr_hv = clr_hold_valid_q;
      /* verilator lint_on UNUSEDSIGNAL */
    end else begin : g_noclr_sram
      assign clr_rd_fire = 1'b0;
      assign clr_rd_set  = '0;
      assign clr_wr_fire = 1'b0;
      assign clr_wr_set  = '0;
      assign clr_wr_way  = '0;
      assign clr_wr_ent  = '0;
      assign clr_wrb_ins = 1'b0;
      assign clr_wrb_tg  = '0;
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_nc;
      assign unused_nc = ^{clr_en, clr_base, clr_pc, raw_clr_rd, busy_after_wr};
      /* verilator lint_on UNUSEDSIGNAL */
    end

    // WRBypass insert (commit update or rare clear)
    assign wrb_wr_en  = new_ftb_wr || clr_wrb_ins;
    assign wrb_wr_key = new_ftb_wr ? {upd_s, upd_tg[TAG_W-1:0]} : {clr_wr_set, clr_wrb_tg};
    if (STORE_B_BASE) begin : g_wrb_p_bb
      assign wrb_wr_data = {sel_way, new_ent, upd_b38};
    end else begin : g_wrb_p_nobb
      assign wrb_wr_data = new_ftb_wr ? {sel_way, new_ent} : {clr_wr_way, clr_wr_ent};
    end

    // 6. Single-way masked 1RW banked SRAM (MASK_W = WAYS -> ZERO T0 read!)
    logic                 sram_wr_en;
    logic [SET_W-1:0]     sram_wr_addr;
    logic [WAYS-1:0]      sram_wr_wmask;
    logic [SET_BITS-1:0]  sram_wr_data, raw_rd0, raw_rd1;

    assign sram_wr_en    = do_ftb_wr || clr_wr_fire;
    assign sram_wr_addr  = do_ftb_wr ? wr_set : clr_wr_set;
    assign sram_wr_wmask = WAYS'(1) << (do_ftb_wr ? wr_way : clr_wr_way);
    assign sram_wr_data  = {WAYS{ENT_BITS'(do_ftb_wr ? wr_ent : clr_wr_ent)}};

    bpu_sram_1rw_banked #(
      .W         (SET_BITS),
      .DEPTH     (SETS),
      .NB        (NB),
      .MASK_W    (WAYS),
      .HAS_RD1   (HAS_RD2),
      .HAS_RST   (1'b0),
      .HAS_CLR_RD(HAS_CLR),
      .HOLD_RD0  (AHEAD_MODE),
      .TAG       (TAG)
    ) u_mem (
      .clk         (clk),
      .rd0_en      (rd_en),
      .rd0_addr    (rd_set0),
      .rd0_data    (raw_rd0),
      .rd1_en      (HAS_RD2 && rd2_en),
      .rd1_addr    (rd_set1),
      .rd1_data    (raw_rd1),
      .clr_rd_en   (HAS_CLR && clr_rd_fire),
      .clr_rd_addr (clr_rd_set),
      .clr_rd_data (raw_clr_rd),
      .wr_en       (sram_wr_en),
      .wr_addr     (sram_wr_addr),
      .wr_data     (sram_wr_data),
      .wr_wmask    (sram_wr_wmask),
      .rst_wr_en   (1'b0),
      .rst_wr_addr ('0),
      .rst_wr_data ('0),
      .rst_wr_wmask('0)
    );

    // Optional parallel 38-bit b_base array for 2-Ahead B (MASK_W = WAYS -> single-way write!)
    if (STORE_B_BASE) begin : g_bbase
      logic [BB_BITS-1:0] bb_rd0, bb_rd1_nc, bb_clr_nc;
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_bb_nc;
      assign unused_bb_nc = ^{bb_rd1_nc, bb_clr_nc};
      /* verilator lint_on UNUSEDSIGNAL */
      assign rd_b_base = bbase_set_t'(bb_rd0);

      bpu_sram_1rw_banked #(
        .W       (BB_BITS),
        .DEPTH   (SETS),
        .NB      (NB),
        .MASK_W  (WAYS),
        .HAS_RD1 (1'b0),
        .HOLD_RD0(1'b1),
        .TAG     ("BPU_AFTB2_BBASE")
      ) u_bbase (
        .clk         (clk),
        .rd0_en      (rd_en),
        .rd0_addr    (rd_set0),
        .rd0_data    (bb_rd0),
        .rd1_en      (1'b0),
        .rd1_addr    ('0),
        .rd1_data    (bb_rd1_nc),
        .clr_rd_en   (1'b0),
        .clr_rd_addr ('0),
        .clr_rd_data (bb_clr_nc),
        .wr_en       (do_ftb_wr),
        .wr_addr     (wr_set),
        .wr_data     ({WAYS{wr_b38}}),
        .wr_wmask    (WAYS'(1) << wr_way),
        .rst_wr_en   (1'b0),
        .rst_wr_addr ('0),
        .rst_wr_data ('0),
        .rst_wr_wmask('0)
      );
    end else begin : g_nobbase
      assign rd_b_base = '0;
    end

    // Lookup read port 0 & optional port 2
    always_comb begin
      logic [FTB_MAX_TAG_W-1:0] rd_tag_v, rd2_tag_v;
      set_t mem_rd1;
      rd_ways  = set_t'(raw_rd0);
      rd_tag_v = norm_tag(rd_cmp_base);
      rd_hit   = 1'b0;
      rd_way   = '0;
      rd_ent   = '0;
      if (!AHEAD_MODE) begin
        for (int w = 0; w < WAYS; w++) begin
          if (!rd_hit && rd_ways[w].valid && (rd_ways[w].tag == rd_tag_v)) begin
            rd_hit = 1'b1; rd_way = WAY_W'(w); rd_ent = rd_ways[w];
          end
        end
      end
      mem_rd1 = HAS_RD2 ? set_t'(raw_rd1) : '0;
      rd2_hit = 1'b0; rd2_way = '0; rd2_ent = '0;
      if (HAS_RD2) begin
        rd2_tag_v = norm_tag(rd2_cmp_base);
        for (int w = 0; w < WAYS; w++) begin
          if (!rd2_hit && mem_rd1[w].valid && (mem_rd1[w].tag == rd2_tag_v)) begin
            rd2_hit = 1'b1; rd2_way = WAY_W'(w); rd2_ent = mem_rd1[w];
          end
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        wb_v_q <= 1'b0;
        wb_s_q <= '0;
        wb_w_q <= '0;
        wb_e_q <= '0;
        wb_b_q <= '0;
      end else begin
        wb_v_q <= wb_v_d;
        wb_s_q <= wb_s_d;
        wb_w_q <= wb_w_d;
        wb_e_q <= wb_e_d;
        wb_b_q <= wb_b_d;
      end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_sram;
    assign unused_sram = ^{rd2_en, rd2_base, rd2_cmp_base, rd_set1, upd_key_base, upd_b_base, wr_b38,
                           upd_br.pred_dir, upd_br.alt_pred, upd_br.pcpn};
    /* verilator lint_on UNUSEDSIGNAL */
  end

endmodule

`default_nettype wire
