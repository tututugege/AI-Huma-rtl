// Ref: front-end/BPU/BpuFtb.h  FtbTab (Pure 1RW SRAM Main FTB u_ftb1, compact 215b/way storage)
`default_nettype none

module bpu_ftb_tab import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    SETS   = FTB_S1_SETS,
  parameter int    WAYS   = FTB_S1_WAYS,
  parameter int    NB     = BPU_FTB1_BANKS,
  parameter int    TAG_W  = FTB_S1_TAG_W,
  parameter [255:0] TAG   = "BPU_FTB1"
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Predict read port 0 (1RW sync launch with rd_en/rd_base)
  input  logic                    rd_en,
  input  logic [XLEN_BITS-1:0]    rd_base,
  input  logic [XLEN_BITS-1:0]    rd_cmp_base,
  output logic                    rd_hit,
  output logic [$clog2(WAYS)-1:0] rd_way,
  output ftb_ent_t                rd_ent,
  // Single-cycle pure commit update (Meta + WRBypass + PLRU; ZERO T0 read)
  input  logic                    upd_en,
  input  logic [XLEN_BITS-1:0]    upd_base,
  input  ftb_br_upd_t             upd_br,
  input  logic                    upd_meta_hit,
  input  logic [$clog2(WAYS)-1:0] upd_meta_way,
  input  ftb_ent_t                upd_meta_ent,
  input  logic [NB-1:0]           rd_bank_mask,
  output logic                    upd_slot_valid,
  output logic [FTB_SLOT_W-1:0]   upd_slot_idx,
  output logic [1:0]              upd_slot_ctr,
  output logic                    upd_any_v,
  output ftb_ent_t                upd_new_ent_o,
  // Rare predecode false-branch slot clear (2-cycle idle-bank read -> single-way write)
  input  logic                    clr_en,
  input  logic [XLEN_BITS-1:0]    clr_base,
  input  logic [XLEN_BITS-1:0]    clr_pc
);

  localparam int SET_W      = $clog2(SETS);
  localparam int WAY_W      = $clog2(WAYS);
  localparam int BK_W       = (NB > 1) ? $clog2(NB) : 1;
  localparam int SLOTS_BITS = $bits(ftb_slot_t) * FTB_SLOTS;
  localparam int STORED_W   = 1 + TAG_W + SLOTS_BITS;
  localparam int SET_BITS   = WAYS * STORED_W;
  localparam int ENT_BITS   = $bits(ftb_ent_t);
  localparam int WRB_KEY_W  = SET_W + TAG_W;
  localparam int WRB_DATA_W = WAY_W + ENT_BITS;

  typedef ftb_ent_t [WAYS-1:0] set_t;

  function automatic logic [STORED_W-1:0] pack_ent(input ftb_ent_t e);
    return {e.valid, e.tag[TAG_W-1:0], e.s};
  endfunction

  function automatic ftb_ent_t unpack_ent(input logic [STORED_W-1:0] raw);
    ftb_ent_t e;
    e = '0;
    e.valid = raw[STORED_W-1];
    e.tag   = FTB_MAX_TAG_W'(raw[SLOTS_BITS +: TAG_W]);
    e.s     = raw[SLOTS_BITS-1:0];
    return e;
  endfunction

  function automatic set_t unpack_set(input logic [SET_BITS-1:0] raw);
    set_t s;
    for (int w = 0; w < WAYS; w++) s[w] = unpack_ent(raw[w * STORED_W +: STORED_W]);
    return s;
  endfunction

  logic [SET_W-1:0]         rd_set0, upd_s;
  logic [FTB_MAX_TAG_W-1:0] upd_tg;
  logic [WAY_W-1:0]         plru_vic, sel_way;
  logic                     wrb_hit, wrb_wr_en, new_ftb_wr;
  logic [WRB_DATA_W-1:0]    wrb_rd_data, wrb_wr_data;
  logic [WRB_KEY_W-1:0]     wrb_rd_key, wrb_wr_key;

  assign rd_set0 = SET_W'(ftb_set_hash(rd_base, SET_W));
  assign upd_s   = SET_W'(ftb_set_hash(upd_base, SET_W));
  assign upd_tg  = FTB_MAX_TAG_W'(ftb_tag_hash(upd_base, SET_W, TAG_W));

  bpu_plru #(.SETS(SETS), .WAYS(WAYS)) u_plru (
    .clk, .rst_n,
    .rd_set(upd_s), .victim_way(plru_vic),
    .touch_en(new_ftb_wr), .touch_set(upd_s), .touch_way(sel_way)
  );

  assign wrb_rd_key = {upd_s, upd_tg[TAG_W-1:0]};
  bpu_wrbypass #(.N(BPU_WRB_N), .KEY_W(WRB_KEY_W), .DATA_W(WRB_DATA_W)) u_wrb (
    .clk, .rst_n,
    .rd_key(wrb_rd_key), .rd_hit(wrb_hit), .rd_data(wrb_rd_data),
    .wr_en(wrb_wr_en), .wr_key(wrb_wr_key), .wr_data(wrb_wr_data)
  );

  logic [WAY_W-1:0] wrb_way;
  ftb_ent_t         wrb_ent, old_ent, cur_ent, new_ent;
  ftb_upsert_res_t  up_res;
  logic             had_hit, any_slot_v;

  assign {wrb_way, wrb_ent} = wrb_rd_data;
  assign upd_new_ent_o      = new_ent;

  always_comb begin
    had_hit = 1'b0; old_ent = '0; sel_way = plru_vic;
    if (wrb_hit) begin
      had_hit = wrb_ent.valid && (wrb_ent.tag == upd_tg);
      old_ent = wrb_ent;
      sel_way = wrb_way;
    end else if (upd_meta_hit) begin
      had_hit = 1'b1;
      old_ent = upd_meta_ent;
      sel_way = upd_meta_way;
    end
    cur_ent = had_hit ? old_ent : '{valid: 1'b1, tag: upd_tg, s: '0};
    up_res  = ftb_upsert_branch(cur_ent, upd_br);
    new_ent = up_res.ent;
    any_slot_v = 1'b0;
    for (int k = 0; k < FTB_SLOTS; k++) if (new_ent.s[k].valid) any_slot_v = 1'b1;
    if (!any_slot_v) new_ent.valid = 1'b0;
    new_ftb_wr     = upd_en && any_slot_v && (!had_hit || !ftb_ent_payload_eq(new_ent, old_ent));
    upd_slot_valid = upd_en && any_slot_v && up_res.slot_found;
    upd_slot_idx   = up_res.slot_idx;
    upd_slot_ctr   = up_res.slot_ctr;
    upd_any_v      = any_slot_v;
  end

  // 1-entry FtbWrBuf (Predict ALWAYS wins 1RW FTB banks)
  logic             wb_v_q, wb_v_d, do_ftb_wr;
  logic [SET_W-1:0] wb_s_q, wb_s_d, wr_set;
  logic [WAY_W-1:0] wb_w_q, wb_w_d, wr_way;
  ftb_ent_t         wb_e_q, wb_e_d, wr_ent;
  logic [NB-1:0]    busy_after_wr;

  always_comb begin
    logic [BK_W-1:0] obk, nbk;
    obk = (NB > 1) ? wb_s_q[BK_W-1:0] : BK_W'(0);
    nbk = (NB > 1) ? upd_s[BK_W-1:0]  : BK_W'(0);
    do_ftb_wr = 1'b0; wr_set = upd_s; wr_way = sel_way; wr_ent = new_ent;
    wb_v_d = 1'b0; wb_s_d = wb_s_q; wb_w_d = wb_w_q; wb_e_d = wb_e_q;
    busy_after_wr = rd_bank_mask;
    if (wb_v_q) begin
      if (!rd_bank_mask[obk]) begin
        do_ftb_wr = 1'b1; wr_set = wb_s_q; wr_way = wb_w_q; wr_ent = wb_e_q;
        busy_after_wr[obk] = 1'b1;
        if (new_ftb_wr) begin wb_v_d = 1'b1; wb_s_d = upd_s; wb_w_d = sel_way; wb_e_d = new_ent; end
      end else begin
        wb_v_d = 1'b1;
        if (new_ftb_wr) begin wb_s_d = upd_s; wb_w_d = sel_way; wb_e_d = new_ent; end
      end
    end else if (new_ftb_wr) begin
      if (!rd_bank_mask[nbk]) begin
        do_ftb_wr = 1'b1; wr_set = upd_s; wr_way = sel_way; wr_ent = new_ent;
        busy_after_wr[nbk] = 1'b1;
      end else begin
        wb_v_d = 1'b1; wb_s_d = upd_s; wb_w_d = sel_way; wb_e_d = new_ent;
      end
    end
  end

  // 2-cycle predecode false-branch slot clear FSM (split into two small comb stages)
  logic                 clr_rd_fire, clr_wr_fire, clr_wrb_ins, clr_hit_c;
  logic [SET_W-1:0]     clr_rd_set, clr_wr_set;
  logic [BK_W-1:0]      clr_t1_bk;
  logic [WAY_W-1:0]     clr_wr_way;
  ftb_ent_t             clr_wr_ent;
  logic [SET_BITS-1:0]  raw_clr_rd;
  logic [TAG_W-1:0]     clr_wrb_tg;
  logic                 clr_pend_v_q, clr_pend_v_d, clr_t1_v_q, clr_t1_v_d;
  logic [XLEN_BITS-1:0] clr_pend_base_q, clr_pend_base_d, clr_pend_pc_q, clr_pend_pc_d;
  logic [XLEN_BITS-1:0] clr_t1_base_q, clr_t1_pc_q;
  logic                 clr_rd_fire_q;
  set_t                 clr_hold_set_q;

  always_comb begin
    set_t                     clr_set_eff;
    logic                     s_any;
    ftb_clr_pos_t             cp;
    logic [FTB_MAX_TAG_W-1:0] t1_tg;
    ftb_ent_t                 c_ent;

    clr_set_eff = clr_rd_fire_q ? unpack_set(raw_clr_rd) : clr_hold_set_q;
    t1_tg       = FTB_MAX_TAG_W'(ftb_tag_hash(clr_t1_base_q, SET_W, TAG_W));
    clr_wr_set  = SET_W'(ftb_set_hash(clr_t1_base_q, SET_W));
    clr_t1_bk   = (NB > 1) ? clr_wr_set[BK_W-1:0] : BK_W'(0);
    cp          = ftb_clr_pos(clr_t1_pc_q, clr_t1_base_q);
    clr_hit_c   = 1'b0; s_any = 1'b0; clr_wr_way = '0; clr_wr_ent = '0; c_ent = '0;
    if (clr_t1_v_q && cp.vok) begin
      for (int w = 0; w < WAYS; w++) begin
        if (!clr_hit_c && clr_set_eff[w].valid && (clr_set_eff[w].tag == t1_tg)) begin
          clr_hit_c  = 1'b1; clr_wr_way = WAY_W'(w); c_ent = clr_set_eff[w]; s_any = 1'b0;
          for (int k = 0; k < FTB_SLOTS; k++) begin
            if (c_ent.s[k].valid && (c_ent.s[k].offset == cp.off)) c_ent.s[k] = '0;
            else if (c_ent.s[k].valid) s_any = 1'b1;
          end
          if (!s_any) c_ent.valid = 1'b0;
          clr_wr_ent = c_ent;
        end
      end
    end
    clr_wrb_tg = t1_tg[TAG_W-1:0];
  end

  always_comb begin
    logic [XLEN_BITS-1:0] cbase;
    logic [SET_W-1:0]     cset;
    logic [BK_W-1:0]      cbk;
    logic                 clr_consumed;

    clr_wr_fire  = clr_t1_v_q && !do_ftb_wr && !new_ftb_wr && !busy_after_wr[clr_t1_bk] && clr_hit_c;
    clr_wrb_ins  = clr_wr_fire;
    clr_t1_v_d   = clr_t1_v_q && clr_hit_c && !clr_wr_fire;
    clr_rd_fire  = 1'b0;
    clr_consumed = 1'b0;
    cbase        = clr_pend_v_q ? clr_pend_base_q : clr_base;
    cset         = SET_W'(ftb_set_hash(cbase, SET_W));
    cbk          = (NB > 1) ? cset[BK_W-1:0] : BK_W'(0);
    clr_rd_set   = cset;
    if (!clr_t1_v_d && (clr_pend_v_q || clr_en)) begin
      if (!busy_after_wr[cbk] && !(clr_wr_fire && (cbk == clr_t1_bk))) begin
        clr_rd_fire  = 1'b1; clr_t1_v_d = 1'b1; clr_consumed = 1'b1;
      end
    end
    clr_pend_v_d = 1'b0; clr_pend_base_d = clr_pend_base_q; clr_pend_pc_d = clr_pend_pc_q;
    if (clr_en && !(clr_consumed && !clr_pend_v_q)) begin
      clr_pend_v_d = 1'b1; clr_pend_base_d = clr_base; clr_pend_pc_d = clr_pc;
    end else if (clr_pend_v_q && !clr_consumed) begin
      clr_pend_v_d = 1'b1;
    end
  end

  assign wrb_wr_en   = new_ftb_wr || clr_wrb_ins;
  assign wrb_wr_key  = new_ftb_wr ? {upd_s, upd_tg[TAG_W-1:0]} : {clr_wr_set, clr_wrb_tg};
  assign wrb_wr_data = new_ftb_wr ? {sel_way, new_ent} : {clr_wr_way, clr_wr_ent};

  logic                sram_wr_en;
  logic [SET_W-1:0]    sram_wr_addr;
  logic [WAYS-1:0]     sram_wr_wmask;
  logic [STORED_W-1:0] wr_packed;
  logic [SET_BITS-1:0] sram_wr_data, raw_rd0;

  assign sram_wr_en    = do_ftb_wr || clr_wr_fire;
  assign sram_wr_addr  = do_ftb_wr ? wr_set : clr_wr_set;
  assign sram_wr_wmask = WAYS'(1) << (do_ftb_wr ? wr_way : clr_wr_way);
  assign wr_packed     = pack_ent(do_ftb_wr ? wr_ent : clr_wr_ent);
  assign sram_wr_data  = {WAYS{wr_packed}};

  bpu_sram_1rw_banked #(
    .W(SET_BITS), .DEPTH(SETS), .NB(NB), .MASK_W(WAYS),
    .HAS_RST(1'b0), .HAS_CLR_RD(1'b1), .HOLD_RD0(1'b0), .TAG(TAG)
  ) u_mem (
    .clk(clk), .rst_n(rst_n),
    .rd0_en(rd_en), .rd0_addr(rd_set0), .rd0_data(raw_rd0),
    .clr_rd_en(clr_rd_fire), .clr_rd_addr(clr_rd_set), .clr_rd_data(raw_clr_rd),
    .wr_en(sram_wr_en), .wr_addr(sram_wr_addr), .wr_data(sram_wr_data), .wr_wmask(sram_wr_wmask),
    .rst_wr_en(1'b0), .rst_wr_addr('0), .rst_wr_data('0), .rst_wr_wmask('0)
  );

  always_comb begin
    set_t                     rd_ways_c;
    logic [FTB_MAX_TAG_W-1:0] rd_tag_v;
    rd_ways_c = unpack_set(raw_rd0);
    rd_tag_v  = FTB_MAX_TAG_W'(ftb_tag_hash(rd_cmp_base, SET_W, TAG_W));
    rd_hit    = 1'b0; rd_way = '0; rd_ent = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (!rd_hit && rd_ways_c[w].valid && (rd_ways_c[w].tag == rd_tag_v)) begin
        rd_hit = 1'b1; rd_way = WAY_W'(w); rd_ent = rd_ways_c[w];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wb_v_q <= 1'b0; wb_s_q <= '0; wb_w_q <= '0; wb_e_q <= '0;
      clr_pend_v_q <= 1'b0; clr_pend_base_q <= '0; clr_pend_pc_q <= '0;
      clr_t1_v_q <= 1'b0; clr_t1_base_q <= '0; clr_t1_pc_q <= '0;
      clr_rd_fire_q <= 1'b0; clr_hold_set_q <= '0;
    end else begin
      wb_v_q <= wb_v_d; wb_s_q <= wb_s_d; wb_w_q <= wb_w_d; wb_e_q <= wb_e_d;
      clr_pend_v_q <= clr_pend_v_d; clr_pend_base_q <= clr_pend_base_d; clr_pend_pc_q <= clr_pend_pc_d;
      clr_t1_v_q <= clr_t1_v_d; clr_rd_fire_q <= clr_rd_fire;
      if (clr_rd_fire) begin
        clr_t1_base_q <= clr_pend_v_q ? clr_pend_base_q : clr_base;
        clr_t1_pc_q   <= clr_pend_v_q ? clr_pend_pc_q   : clr_pc;
      end
      if (clr_rd_fire_q) clr_hold_set_q <= unpack_set(raw_clr_rd);
    end
  end

  logic unused_sram;
  assign unused_sram = ^{upd_br.pred_dir, upd_br.alt_pred, upd_br.pcpn};

endmodule
`default_nettype wire
