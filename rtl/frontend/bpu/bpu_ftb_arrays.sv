// Ref: front-end/BPU/BpuFtb.h  struct BpuFtb (uFTB FF + strict sync 1R1W SRAMs for Main FTB, S2 TAGE/SC/ITT, 1-Ahead A & 2-Ahead B)
`default_nettype none

module bpu_ftb_arrays import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // S0 lookup (comb uFTB + pre-launch Main FTB port 0 + sync 1-Ahead A & 2-Ahead B SRAM read)
  input  logic [XLEN_BITS-1:0] s0_base,
  input  logic [XLEN_BITS-1:0] s0_b_base,
  input  logic                 ah_rd_en,
  input  logic [XLEN_BITS-1:0] ah_rd_base,
  input  ftb_ix_t              ah_rd_ix,
  output logic                 ftb0_hit,
  output ftb_ent_t             ftb0_ent,
  output logic                 ftb0_b_hit,
  output ftb_ent_t             ftb0_b_ent,
  output ftb_ah_raw_t          ah_sram_raw,
  output ftb_ah_raw_t          ah2_sram_raw,
  output logic                 ah_prefer_alt,
  output logic                 ah2_prefer_alt,
  // S1 -> S2 lookup:
  //   - u_ftb1 port 0 was pre-launched at t-1 with s0_base -> tag-compared at t with s1_base -> s1_ftb_hit/ent
  //   - u_ftb1 port 2 & S2 TAGE/SC/ITT launch at t with s1_* -> outputs arrive directly at t+1 (S2)
  input  logic [XLEN_BITS-1:0] s1_base,
  input  ftb_ix_t              s1_ix,
  input  ex_tage_ix_t          s1_ex_ix,
  input  sc_ix_t               s1_sc_ix,
  input  logic [XLEN_BITS-1:0] s1_b_base,
  input  logic [XLEN_BITS-1:0] s2_b_base,
  input  ftb_ix_t              s1_b_ix,
  input  ex_tage_ix_t          s1_b_ex_ix,
  input  sc_ix_t               s1_b_sc_ix,
  output logic                 s1_ftb_hit,
  output ftb_ent_t             s1_ftb_ent,
  output logic                 s2_b_ftb_hit,
  output ftb_ent_t             s2_b_ftb_ent,
  output ex_tage_raw_t         s2_tage_raw,
  output sc_raw_t              s2_sc_raw,
  output ftb_itt_raw_t         s2_itt_raw,
  output ex_tage_raw_t         s2_b_tage_raw,
  output sc_raw_t              s2_b_sc_raw,
  output ftb_itt_raw_t         s2_b_itt_raw,
  output logic [15:0][3:0]     s2_use_alt,
  output logic [15:0][5:0]     s2_sc_thres,
  // Single-branch commit training T0 input (2-stage sync RMW: T0 read -> T1 modify & write)
  input  logic                 upd_en,
  input  logic [XLEN_BITS-1:0] upd_start,
  input  ftb_ix_t              upd_ix,
  input  ex_tage_ix_t          upd_ex_ix,
  input  sc_ix_t               upd_sc_ix,
  input  logic                 upd_ah_v,
  input  logic                 upd_ah_kind, // 0 = 1-ahead A (aftb), 1 = 2-ahead B (aftb2)
  input  logic [XLEN_BITS-1:0] upd_ah_key_base,
  input  logic [XLEN_BITS-1:0] upd_ah_a_base,
  input  ftb_ix_t              upd_ah_ix,
  input  ftb_br_upd_t          upd_br,
  // Predecode false-branch slot clear (arbitrated against upd_en via 1-entry clr_pend_q)
  input  logic                 clr_en,
  input  logic [XLEN_BITS-1:0] clr_base,
  input  logic [XLEN_BITS-1:0] clr_pc
);

  // ---- T0 -> T1 training pipeline & 1-entry clr_pend arbitration (upd takes priority over clr on FTB1 1W port) ----
  logic                 t1_en_q, t1_ah_v_q, t1_ah_kind_q;
  logic [XLEN_BITS-1:0] t1_start_q, t1_ah_key_base_q, t1_ah_a_base_q;
  ftb_ix_t              t1_ix_q, t1_ah_ix_q;
  ex_tage_ix_t          t1_ex_ix_q;
  sc_ix_t               t1_sc_ix_q;
  ftb_br_upd_t          t1_br_q;

  logic                 clr_pend_v_q, clr_pend_v_d;
  logic [XLEN_BITS-1:0] clr_pend_base_q, clr_pend_base_d;
  logic [XLEN_BITS-1:0] clr_pend_pc_q, clr_pend_pc_d;
  logic                 t0_clr_issue;
  logic [XLEN_BITS-1:0] t0_clr_base, t0_clr_pc;
  logic                 t1_clr_en_q;
  logic [XLEN_BITS-1:0] t1_clr_base_q, t1_clr_pc_q;

  always_comb begin
    t0_clr_issue    = 1'b0;
    t0_clr_base     = clr_base;
    t0_clr_pc       = clr_pc;
    clr_pend_v_d    = clr_pend_v_q;
    clr_pend_base_d = clr_pend_base_q;
    clr_pend_pc_d   = clr_pend_pc_q;

    if (upd_en) begin
      if (clr_en) begin
        clr_pend_v_d    = 1'b1;
        clr_pend_base_d = clr_base;
        clr_pend_pc_d   = clr_pc;
      end
    end else if (clr_pend_v_q) begin
      t0_clr_issue = 1'b1;
      t0_clr_base  = clr_pend_base_q;
      t0_clr_pc    = clr_pend_pc_q;
      if (clr_en) begin
        clr_pend_v_d    = 1'b1;
        clr_pend_base_d = clr_base;
        clr_pend_pc_d   = clr_pc;
      end else begin
        clr_pend_v_d    = 1'b0;
      end
    end else if (clr_en) begin
      t0_clr_issue = 1'b1;
      t0_clr_base  = clr_base;
      t0_clr_pc    = clr_pc;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      t1_en_q         <= 1'b0;
      t1_clr_en_q     <= 1'b0;
      clr_pend_v_q    <= 1'b0;
      clr_pend_base_q <= '0;
      clr_pend_pc_q   <= '0;
    end else begin
      t1_en_q         <= upd_en;
      t1_clr_en_q     <= t0_clr_issue;
      clr_pend_v_q    <= clr_pend_v_d;
      clr_pend_base_q <= clr_pend_base_d;
      clr_pend_pc_q   <= clr_pend_pc_d;
    end
  end

  always_ff @(posedge clk) begin
    if (upd_en) begin
      t1_start_q       <= upd_start;
      t1_ix_q          <= upd_ix;
      t1_ex_ix_q       <= upd_ex_ix;
      t1_sc_ix_q       <= upd_sc_ix;
      t1_ah_v_q        <= upd_ah_v;
      t1_ah_kind_q     <= upd_ah_kind;
      t1_ah_key_base_q <= upd_ah_key_base;
      t1_ah_a_base_q   <= upd_ah_a_base;
      t1_ah_ix_q       <= upd_ah_ix;
      t1_br_q          <= upd_br;
    end
    if (t0_clr_issue) begin
      t1_clr_base_q <= t0_clr_base;
      t1_clr_pc_q   <= t0_clr_pc;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  ftb_ent_t [FTB_S0_WAYS-1:0] ftb0_ways_nc;
  ftb_ent_t [FTB_S1_WAYS-1:0] ftb1_ways_nc;
  logic [FTB_S0_WAYS-1:0][XLEN_BITS-1:0] ftb0_bb_nc;
  logic [FTB_S1_WAYS-1:0][XLEN_BITS-1:0] ftb1_bb_nc;
  logic [FTB_AH_WAYS-1:0][XLEN_BITS-1:0] aftb_bb_nc;
  logic                       ftb0_sl_v_nc, aftb_hit_nc, aftb2_hit_nc;
  logic                       aftb_rd2_hit_nc, aftb2_rd2_hit_nc;
  logic [FTB_SLOT_W-1:0]      ftb0_sl_idx_nc;
  logic [1:0]                 ftb0_sl_ctr_nc, ftb1_sl_ctr_nc;
  ftb_ent_t                   aftb_ent_nc, aftb2_ent_nc, aftb_rd2_ent_nc, aftb2_rd2_ent_nc;
  ftb_tage_raw_t              atage_rd2_nc, atage2_rd2_nc;
  ftb_itt_raw_t               aitt_rd2_nc, aitt2_rd2_nc;
  /* verilator lint_on UNUSEDSIGNAL */

  logic                  ftb1_sl_v, aftb_sl_v, aftb2_sl_v;
  logic [FTB_SLOT_W-1:0] ftb1_sl_idx, aftb_sl_idx, aftb2_sl_idx;
  logic [1:0]            aftb_sl_ctr, aftb2_sl_ctr;

  // ---- Small S0 uFTB (64x4, FF register file for 0-cycle S0 loop; updated in T1) ----
  bpu_ftb_tab #(
    .SETS(FTB_S0_SETS), .WAYS(FTB_S0_WAYS), .TAG_W(FTB_S0_TAG_W), .TGT_BITS(FTB_S0_TGT_B),
    .ALLOC_ONLY_TAKEN(1'b1), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .HAS_RD2(1'b1), .USE_SRAM(1'b0)
  ) u_ftb0 (
    .clk, .rst_n,
    .rd_en(1'b1), .rd_base(s0_base), .rd_cmp_base(s0_base),
    .rd_hit(ftb0_hit), .rd_ent(ftb0_ent), .rd_ways(ftb0_ways_nc), .rd_b_base(ftb0_bb_nc),
    .rd2_en(1'b1), .rd2_base(s0_b_base), .rd2_cmp_base(s0_b_base),
    .rd2_hit(ftb0_b_hit), .rd2_ent(ftb0_b_ent),
    .t0_upd_en(1'b0), .t0_upd_base('0), .t0_upd_key_base('0),
    .t0_clr_en(1'b0), .t0_clr_base('0),
    .t1_upd_en(t1_en_q), .t1_upd_base(t1_start_q), .t1_upd_key_base('0), .t1_upd_b_base('0), .t1_upd_br(t1_br_q),
    .upd_slot_valid(ftb0_sl_v_nc), .upd_slot_idx(ftb0_sl_idx_nc), .upd_slot_ctr(ftb0_sl_ctr_nc),
    .t1_clr_en(t1_clr_en_q), .t1_clr_base(t1_clr_base_q), .t1_clr_pc(t1_clr_pc_q)
  );

  // ---- Main FTB (1024x4, strict sync 1R1W SRAM):
  //      Port 0 (WF=1): pre-launched at t-1 with s0_base -> compared at t with s1_base (r0_q.base)
  //      Port 1 (WF=1): T0->T1 shared upd/clr RMW
  //      Port 2 (WF=0): launched at t with s1_b_base (r0_q.base_b) -> compared at t+1 with s2_b_base (r1_q.base_b)
  bpu_ftb_tab #(
    .SETS(FTB_S1_SETS), .WAYS(FTB_S1_WAYS), .TAG_W(FTB_S1_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .HAS_RD2(1'b1),
    .USE_SRAM(1'b1), .RD_WF_MASK(3'b011), .TAG("BPU_FTB1")
  ) u_ftb1 (
    .clk, .rst_n,
    .rd_en(1'b1), .rd_base(s0_base), .rd_cmp_base(s1_base),
    .rd_hit(s1_ftb_hit), .rd_ent(s1_ftb_ent), .rd_ways(ftb1_ways_nc), .rd_b_base(ftb1_bb_nc),
    .rd2_en(1'b1), .rd2_base(s1_b_base), .rd2_cmp_base(s2_b_base),
    .rd2_hit(s2_b_ftb_hit), .rd2_ent(s2_b_ftb_ent),
    .t0_upd_en(upd_en), .t0_upd_base(upd_start), .t0_upd_key_base('0),
    .t0_clr_en(t0_clr_issue), .t0_clr_base(t0_clr_base),
    .t1_upd_en(t1_en_q), .t1_upd_base(t1_start_q), .t1_upd_key_base('0), .t1_upd_b_base('0), .t1_upd_br(t1_br_q),
    .upd_slot_valid(ftb1_sl_v), .upd_slot_idx(ftb1_sl_idx), .upd_slot_ctr(ftb1_sl_ctr_nc),
    .t1_clr_en(t1_clr_en_q), .t1_clr_base(t1_clr_base_q), .t1_clr_pc(t1_clr_pc_q)
  );

  logic       t0_s2_upd_en, t1_s2_upd_en, s2_live_pred, s2_live_prov_hit;
  logic [2:0] s2_live_prov_cnt;
  logic [1:0] s2_live_base_cnt;
  assign t0_s2_upd_en = upd_en  && (upd_br.br_type  == BR_DIRECT);
  assign t1_s2_upd_en = t1_en_q && (t1_br_q.br_type == BR_DIRECT) && ftb1_sl_v;

  bpu_ftb_ex_tage u_s2_tage (
    .clk, .rst_n,
    .rd_ix(s1_ex_ix), .rd2_ix(s1_b_ex_ix),
    .rd_raw(s2_tage_raw), .rd2_raw(s2_b_tage_raw),
    .use_alt_o(s2_use_alt),
    .t0_upd_en(t0_s2_upd_en), .t0_upd_ix(upd_ex_ix),
    .t1_upd_en(t1_s2_upd_en), .t1_upd_ix(t1_ex_ix_q), .t1_upd_sl(ftb1_sl_idx), .t1_upd_real_dir(t1_br_q.actual_dir),
    .upd_live_pred(s2_live_pred), .upd_live_prov_hit(s2_live_prov_hit),
    .upd_live_prov_cnt(s2_live_prov_cnt), .upd_live_base_cnt(s2_live_base_cnt)
  );

  bpu_ftb_sc u_s2_sc (
    .clk, .rst_n,
    .rd_ix(s1_sc_ix), .rd2_ix(s1_b_sc_ix),
    .rd_raw(s2_sc_raw), .rd2_raw(s2_b_sc_raw),
    .thres_o(s2_sc_thres),
    .t0_upd_en(t0_s2_upd_en), .t0_upd_ix(upd_sc_ix),
    .t1_upd_en(t1_s2_upd_en), .t1_upd_ix(t1_sc_ix_q), .t1_upd_sl(ftb1_sl_idx), .t1_upd_real_dir(t1_br_q.actual_dir),
    .upd_tage_pred(s2_live_pred), .upd_prov_hit(s2_live_prov_hit),
    .upd_prov_cnt(s2_live_prov_cnt), .upd_base_cnt(s2_live_base_cnt)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .HAS_RD2(1'b1), .TAG("BPU_S2_ITT")) u_s2_itt (
    .clk, .rst_n,
    .rd_en(1'b1), .rd2_en(1'b1),
    .rd_ix(s1_ix), .rd2_ix(s1_b_ix), .rd_raw(s2_itt_raw), .rd2_raw(s2_b_itt_raw),
    .t0_upd_en(upd_en  && ftb_br_ind(upd_br.br_type)  && upd_br.actual_dir),  .t0_upd_ix(upd_ix),
    .t1_upd_en(t1_en_q && ftb_br_ind(t1_br_q.br_type) && t1_br_q.actual_dir), .t1_upd_ix(t1_ix_q), .t1_upd_target(t1_br_q.target)
  );

  // ---- 1-Ahead A arrays (2K x 8 FTB, 1K x 4 x 4 TAGE, 256 x 3 ITT, strict sync 1R1W SRAM) ----
  assign ah_sram_raw.b_base = '0;
  logic t0_upd_ah1, t0_upd_ah2, t1_upd_ah1, t1_upd_ah2;
  assign t0_upd_ah1 = upd_en  && upd_ah_v  && !upd_ah_kind;
  assign t0_upd_ah2 = upd_en  && upd_ah_v  &&  upd_ah_kind;
  assign t1_upd_ah1 = t1_en_q && t1_ah_v_q && !t1_ah_kind_q;
  assign t1_upd_ah2 = t1_en_q && t1_ah_v_q &&  t1_ah_kind_q;

  bpu_ftb_tab #(
    .SETS(FTB_AH_SETS), .WAYS(FTB_AH_WAYS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .HAS_RD2(1'b0), .STORE_B_BASE(1'b0),
    .USE_SRAM(1'b1), .RD_WF_MASK(3'b010), .TAG("BPU_AFTB")
  ) u_aftb (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_base(ah_rd_base), .rd_cmp_base('0),
    .rd_hit(aftb_hit_nc), .rd_ent(aftb_ent_nc), .rd_ways(ah_sram_raw.ftb_ways), .rd_b_base(aftb_bb_nc),
    .rd2_en(1'b0), .rd2_base('0), .rd2_cmp_base('0), .rd2_hit(aftb_rd2_hit_nc), .rd2_ent(aftb_rd2_ent_nc),
    .t0_upd_en(t0_upd_ah1), .t0_upd_base(upd_start), .t0_upd_key_base(upd_ah_key_base),
    .t0_clr_en(1'b0), .t0_clr_base('0),
    .t1_upd_en(t1_upd_ah1), .t1_upd_base(t1_start_q), .t1_upd_key_base(t1_ah_key_base_q), .t1_upd_b_base('0), .t1_upd_br(t1_br_q),
    .upd_slot_valid(aftb_sl_v), .upd_slot_idx(aftb_sl_idx), .upd_slot_ctr(aftb_sl_ctr),
    .t1_clr_en(1'b0), .t1_clr_base('0), .t1_clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH_TAGE_N), .HAS_BASE(1'b0), .USE_LIVE_PRED(1'b1), .HAS_RD2(1'b0), .TAG("BPU_ATAGE")) u_atage (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd2_en(1'b0),
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah_sram_raw.tage_raw), .rd2_raw(atage_rd2_nc),
    .prefer_alt(ah_prefer_alt),
    .t0_upd_en(t0_upd_ah1 && (upd_br.br_type == BR_DIRECT)), .t0_upd_ix(upd_ah_ix),
    .t1_upd_en(t1_upd_ah1 && (t1_br_q.br_type == BR_DIRECT) && aftb_sl_v),
    .t1_upd_ix(t1_ah_ix_q), .t1_upd_sl(aftb_sl_idx), .t1_upd_real_dir(t1_br_q.actual_dir),
    .t1_upd_pred_dir(1'b0), .t1_upd_alt_pred(1'b0), .t1_upd_pcpn(3'd0), .t1_upd_base_ctr(aftb_sl_ctr)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .HAS_RD2(1'b0), .TAG("BPU_AITT")) u_aitt (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd2_en(1'b0),
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah_sram_raw.itt_raw), .rd2_raw(aitt_rd2_nc),
    .t0_upd_en(t0_upd_ah1 && ftb_br_ind(upd_br.br_type)  && upd_br.actual_dir),  .t0_upd_ix(upd_ah_ix),
    .t1_upd_en(t1_upd_ah1 && ftb_br_ind(t1_br_q.br_type) && t1_br_q.actual_dir), .t1_upd_ix(t1_ah_ix_q), .t1_upd_target(t1_br_q.target)
  );

  // ---- 2-Ahead B companion arrays (1K x 8 FTB keyed on a_base + b_base, 512 x 4 x 4 TAGE, 256 x 3 ITT) ----
  bpu_ftb_tab #(
    .SETS(FTB_AH2_SETS), .WAYS(FTB_AH2_WAYS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .HAS_RD2(1'b0), .STORE_B_BASE(1'b1),
    .USE_SRAM(1'b1), .RD_WF_MASK(3'b010), .TAG("BPU_AFTB2")
  ) u_aftb2 (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_base(ah_rd_base), .rd_cmp_base('0),
    .rd_hit(aftb2_hit_nc), .rd_ent(aftb2_ent_nc), .rd_ways(ah2_sram_raw.ftb_ways), .rd_b_base(ah2_sram_raw.b_base),
    .rd2_en(1'b0), .rd2_base('0), .rd2_cmp_base('0), .rd2_hit(aftb2_rd2_hit_nc), .rd2_ent(aftb2_rd2_ent_nc),
    .t0_upd_en(t0_upd_ah2), .t0_upd_base(upd_ah_a_base), .t0_upd_key_base(upd_ah_key_base),
    .t0_clr_en(1'b0), .t0_clr_base('0),
    .t1_upd_en(t1_upd_ah2), .t1_upd_base(t1_ah_a_base_q), .t1_upd_key_base(t1_ah_key_base_q), .t1_upd_b_base(t1_start_q), .t1_upd_br(t1_br_q),
    .upd_slot_valid(aftb2_sl_v), .upd_slot_idx(aftb2_sl_idx), .upd_slot_ctr(aftb2_sl_ctr),
    .t1_clr_en(1'b0), .t1_clr_base('0), .t1_clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH2_TAGE_N), .HAS_BASE(1'b0), .USE_LIVE_PRED(1'b1), .HAS_RD2(1'b0), .TAG("BPU_ATAGE2")) u_atage2 (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd2_en(1'b0),
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah2_sram_raw.tage_raw), .rd2_raw(atage2_rd2_nc),
    .prefer_alt(ah2_prefer_alt),
    .t0_upd_en(t0_upd_ah2 && (upd_br.br_type == BR_DIRECT)), .t0_upd_ix(upd_ah_ix),
    .t1_upd_en(t1_upd_ah2 && (t1_br_q.br_type == BR_DIRECT) && aftb2_sl_v),
    .t1_upd_ix(t1_ah_ix_q), .t1_upd_sl(aftb2_sl_idx), .t1_upd_real_dir(t1_br_q.actual_dir),
    .t1_upd_pred_dir(1'b0), .t1_upd_alt_pred(1'b0), .t1_upd_pcpn(3'd0), .t1_upd_base_ctr(aftb2_sl_ctr)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .HAS_RD2(1'b0), .TAG("BPU_AITT2")) u_aitt2 (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd2_en(1'b0),
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah2_sram_raw.itt_raw), .rd2_raw(aitt2_rd2_nc),
    .t0_upd_en(t0_upd_ah2 && ftb_br_ind(upd_br.br_type)  && upd_br.actual_dir),  .t0_upd_ix(upd_ah_ix),
    .t1_upd_en(t1_upd_ah2 && ftb_br_ind(t1_br_q.br_type) && t1_br_q.actual_dir), .t1_upd_ix(t1_ah_ix_q), .t1_upd_target(t1_br_q.target)
  );

endmodule

`default_nettype wire
