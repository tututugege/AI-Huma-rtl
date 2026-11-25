// Ref: front-end/BPU/BpuFtb.h  struct BpuFtb (uFTB, Main FTB, S2 TAGE/ITT, 1-Ahead A & 2-Ahead B arrays)
`default_nettype none

module bpu_ftb_arrays import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // S0 lookup (dual-port uFTB for A & B fallback + parallel 1-Ahead A & 2-Ahead B SRAM read)
  input  logic [XLEN_BITS-1:0] s0_base,
  input  logic [XLEN_BITS-1:0] s0_b_base,
  input  logic [XLEN_BITS-1:0] ah_rd_base,
  input  ftb_ix_t              ah_rd_ix,
  output logic                 ftb0_hit,
  output ftb_ent_t             ftb0_ent,
  output logic                 ftb0_b_hit,
  output ftb_ent_t             ftb0_b_ent,
  output ftb_ah_raw_t          ah_rd_raw,
  output ftb_ah_raw_t          ah2_rd_raw,
  output logic                 ah_prefer_alt,
  output logic                 ah2_prefer_alt,
  // S1 dual lookup (Main FTB + S2 ExBlockTage + S2 SC + S2 Block-ITT for Block A & Block B)
  input  logic [XLEN_BITS-1:0] s1_base,
  input  ftb_ix_t              s1_ix,
  input  ex_tage_ix_t          s1_ex_ix,
  input  sc_ix_t               s1_sc_ix,
  input  logic [XLEN_BITS-1:0] s1_b_base,
  input  ftb_ix_t              s1_b_ix,
  input  ex_tage_ix_t          s1_b_ex_ix,
  input  sc_ix_t               s1_b_sc_ix,
  output ftb_s1_raw_t          s1_raw,
  output ftb_s1_raw_t          s1_b_raw,
  output logic [15:0][3:0]     s2_use_alt,
  output logic [15:0][5:0]     s2_sc_thres,
  // Single-branch commit training (BRQ_W=1)
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
  // Predecode false-branch slot clear
  input  logic                 clr_en,
  input  logic [XLEN_BITS-1:0] clr_base,
  input  logic [XLEN_BITS-1:0] clr_pc
);

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

  bpu_ftb_tab #(
    .SETS(FTB_S0_SETS), .WAYS(FTB_S0_WAYS), .TAG_W(FTB_S0_TAG_W), .TGT_BITS(FTB_S0_TGT_B),
    .ALLOC_ONLY_TAKEN(1'b1), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .HAS_RD2(1'b1)
  ) u_ftb0 (
    .clk, .rst_n,
    .rd_base(s0_base), .rd_hit(ftb0_hit), .rd_ent(ftb0_ent), .rd_ways(ftb0_ways_nc), .rd_b_base(ftb0_bb_nc),
    .rd2_base(s0_b_base), .rd2_hit(ftb0_b_hit), .rd2_ent(ftb0_b_ent),
    .upd_en, .upd_base(upd_start), .upd_key_base('0), .upd_b_base('0), .upd_br,
    .upd_slot_valid(ftb0_sl_v_nc), .upd_slot_idx(ftb0_sl_idx_nc), .upd_slot_ctr(ftb0_sl_ctr_nc),
    .clr_en, .clr_base, .clr_pc
  );

  bpu_ftb_tab #(
    .SETS(FTB_S1_SETS), .WAYS(FTB_S1_WAYS), .TAG_W(FTB_S1_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .HAS_RD2(1'b1)
  ) u_ftb1 (
    .clk, .rst_n,
    .rd_base(s1_base), .rd_hit(s1_raw.ftb_hit), .rd_ent(s1_raw.ent), .rd_ways(ftb1_ways_nc), .rd_b_base(ftb1_bb_nc),
    .rd2_base(s1_b_base), .rd2_hit(s1_b_raw.ftb_hit), .rd2_ent(s1_b_raw.ent),
    .upd_en, .upd_base(upd_start), .upd_key_base('0), .upd_b_base('0), .upd_br,
    .upd_slot_valid(ftb1_sl_v), .upd_slot_idx(ftb1_sl_idx), .upd_slot_ctr(ftb1_sl_ctr_nc),
    .clr_en, .clr_base, .clr_pc
  );

  logic       s2_upd_en, s2_live_pred, s2_live_prov_hit;
  logic [2:0] s2_live_prov_cnt;
  logic [1:0] s2_live_base_cnt;
  assign s2_upd_en = upd_en && (upd_br.br_type == BR_DIRECT) && ftb1_sl_v;

  bpu_ftb_ex_tage u_s2_tage (
    .clk, .rst_n,
    .rd_ix(s1_ex_ix), .rd2_ix(s1_b_ex_ix),
    .rd_raw(s1_raw.s2_tage_raw), .rd2_raw(s1_b_raw.s2_tage_raw),
    .use_alt_o(s2_use_alt),
    .upd_en(s2_upd_en),
    .upd_ix(upd_ex_ix), .upd_sl(ftb1_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_live_pred(s2_live_pred), .upd_live_prov_hit(s2_live_prov_hit),
    .upd_live_prov_cnt(s2_live_prov_cnt), .upd_live_base_cnt(s2_live_base_cnt)
  );

  bpu_ftb_sc u_s2_sc (
    .clk, .rst_n,
    .rd_ix(s1_sc_ix), .rd2_ix(s1_b_sc_ix),
    .rd_raw(s1_raw.s2_sc_raw), .rd2_raw(s1_b_raw.s2_sc_raw),
    .thres_o(s2_sc_thres),
    .upd_en(s2_upd_en),
    .upd_ix(upd_sc_ix), .upd_sl(ftb1_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_tage_pred(s2_live_pred), .upd_prov_hit(s2_live_prov_hit),
    .upd_prov_cnt(s2_live_prov_cnt), .upd_base_cnt(s2_live_base_cnt)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .HAS_RD2(1'b1)) u_s2_itt (
    .clk, .rst_n,
    .rd_ix(s1_ix), .rd2_ix(s1_b_ix), .rd_raw(s1_raw.itt_raw), .rd2_raw(s1_b_raw.itt_raw),
    .upd_en(upd_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir),
    .upd_ix, .upd_target(upd_br.target)
  );

  // ---- 1-Ahead A arrays (2K x 8 FTB, 1K x 4 x 4 TAGE, 256 x 3 ITT) ----
  assign ah_rd_raw.b_base = '0;
  logic upd_ah1, upd_ah2;
  assign upd_ah1 = upd_en && upd_ah_v && !upd_ah_kind;
  assign upd_ah2 = upd_en && upd_ah_v &&  upd_ah_kind;

  bpu_ftb_tab #(
    .SETS(FTB_AH_SETS), .WAYS(FTB_AH_WAYS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .HAS_RD2(1'b0), .STORE_B_BASE(1'b0)
  ) u_aftb (
    .clk, .rst_n,
    .rd_base(ah_rd_base), .rd_hit(aftb_hit_nc), .rd_ent(aftb_ent_nc), .rd_ways(ah_rd_raw.ftb_ways), .rd_b_base(aftb_bb_nc),
    .rd2_base('0), .rd2_hit(aftb_rd2_hit_nc), .rd2_ent(aftb_rd2_ent_nc),
    .upd_en(upd_ah1), .upd_base(upd_start), .upd_key_base(upd_ah_key_base), .upd_b_base('0), .upd_br,
    .upd_slot_valid(aftb_sl_v), .upd_slot_idx(aftb_sl_idx), .upd_slot_ctr(aftb_sl_ctr),
    .clr_en(1'b0), .clr_base('0), .clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH_TAGE_N), .HAS_BASE(1'b0), .USE_LIVE_PRED(1'b1), .HAS_RD2(1'b0)) u_atage (
    .clk, .rst_n,
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah_rd_raw.tage_raw), .rd2_raw(atage_rd2_nc),
    .prefer_alt(ah_prefer_alt),
    .upd_en(upd_ah1 && (upd_br.br_type == BR_DIRECT) && aftb_sl_v),
    .upd_ix(upd_ah_ix), .upd_sl(aftb_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_pred_dir(1'b0), .upd_alt_pred(1'b0), .upd_pcpn(3'd0), .upd_base_ctr(aftb_sl_ctr)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .HAS_RD2(1'b0)) u_aitt (
    .clk, .rst_n,
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah_rd_raw.itt_raw), .rd2_raw(aitt_rd2_nc),
    .upd_en(upd_ah1 && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir),
    .upd_ix(upd_ah_ix), .upd_target(upd_br.target)
  );

  // ---- 2-Ahead B companion arrays (1K x 8 FTB keyed on a_base + b_base, 512 x 4 x 4 TAGE, 256 x 3 ITT) ----
  bpu_ftb_tab #(
    .SETS(FTB_AH2_SETS), .WAYS(FTB_AH2_WAYS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .HAS_RD2(1'b0), .STORE_B_BASE(1'b1)
  ) u_aftb2 (
    .clk, .rst_n,
    .rd_base(ah_rd_base), .rd_hit(aftb2_hit_nc), .rd_ent(aftb2_ent_nc), .rd_ways(ah2_rd_raw.ftb_ways), .rd_b_base(ah2_rd_raw.b_base),
    .rd2_base('0), .rd2_hit(aftb2_rd2_hit_nc), .rd2_ent(aftb2_rd2_ent_nc),
    .upd_en(upd_ah2), .upd_base(upd_ah_a_base), .upd_key_base(upd_ah_key_base), .upd_b_base(upd_start), .upd_br,
    .upd_slot_valid(aftb2_sl_v), .upd_slot_idx(aftb2_sl_idx), .upd_slot_ctr(aftb2_sl_ctr),
    .clr_en(1'b0), .clr_base('0), .clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH2_TAGE_N), .HAS_BASE(1'b0), .USE_LIVE_PRED(1'b1), .HAS_RD2(1'b0)) u_atage2 (
    .clk, .rst_n,
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah2_rd_raw.tage_raw), .rd2_raw(atage2_rd2_nc),
    .prefer_alt(ah2_prefer_alt),
    .upd_en(upd_ah2 && (upd_br.br_type == BR_DIRECT) && aftb2_sl_v),
    .upd_ix(upd_ah_ix), .upd_sl(aftb2_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_pred_dir(1'b0), .upd_alt_pred(1'b0), .upd_pcpn(3'd0), .upd_base_ctr(aftb2_sl_ctr)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .HAS_RD2(1'b0)) u_aitt2 (
    .clk, .rst_n,
    .rd_ix(ah_rd_ix), .rd2_ix('0), .rd_raw(ah2_rd_raw.itt_raw), .rd2_raw(aitt2_rd2_nc),
    .upd_en(upd_ah2 && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir),
    .upd_ix(upd_ah_ix), .upd_target(upd_br.target)
  );

endmodule

`default_nettype wire
