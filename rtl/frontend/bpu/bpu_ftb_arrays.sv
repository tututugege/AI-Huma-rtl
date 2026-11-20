// Ref: front-end/BPU/BpuFtb.h  struct BpuFtb (uFTB, Main FTB, S2 TAGE/ITT, Ahead FTB/TAGE/ITT arrays)
`default_nettype none

module bpu_ftb_arrays import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // S0 lookup (uFTB + ahead SRAM read)
  input  logic [XLEN_BITS-1:0] s0_base,
  input  ftb_ix_t              ah_rd_ix,
  output logic                 ftb0_hit,
  output ftb_ent_t             ftb0_ent,
  output ftb_ah_raw_t          ah_rd_raw,
  output logic                 ah_prefer_alt,
  // S1 lookup (Main FTB + S2 Block-TAGE + S2 Block-ITT)
  input  logic [XLEN_BITS-1:0] s1_base,
  input  ftb_ix_t              s1_ix,
  output ftb_s1_raw_t          s1_raw,
  output logic                 s2_prefer_alt,
  // Single-branch commit training
  input  logic                 upd_en,
  input  logic [XLEN_BITS-1:0] upd_start,
  input  ftb_ix_t              upd_ix,
  input  logic                 upd_ah_v,
  input  logic [XLEN_BITS-1:0] upd_ah_key_base,
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
  logic                       ftb0_sl_v_nc, aftb_hit_nc;
  logic [FTB_SLOT_W-1:0]      ftb0_sl_idx_nc;
  logic [1:0]                 ftb0_sl_ctr_nc, ftb1_sl_ctr_nc;
  ftb_ent_t                   aftb_ent_nc;
  /* verilator lint_on UNUSEDSIGNAL */

  logic                  ftb1_sl_v, aftb_sl_v;
  logic [FTB_SLOT_W-1:0] ftb1_sl_idx, aftb_sl_idx;
  logic [1:0]            aftb_sl_ctr;

  bpu_ftb_tab #(
    .SETS(FTB_S0_SETS), .WAYS(FTB_S0_WAYS), .TAG_W(FTB_S0_TAG_W), .TGT_BITS(FTB_S0_TGT_B),
    .ALLOC_ONLY_TAKEN(1'b1), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1)
  ) u_ftb0 (
    .clk, .rst_n, .rd_base(s0_base), .rd_hit(ftb0_hit), .rd_ent(ftb0_ent), .rd_ways(ftb0_ways_nc),
    .upd_en, .upd_base(upd_start), .upd_key_base('0), .upd_br,
    .upd_slot_valid(ftb0_sl_v_nc), .upd_slot_idx(ftb0_sl_idx_nc), .upd_slot_ctr(ftb0_sl_ctr_nc),
    .clr_en, .clr_base, .clr_pc
  );

  bpu_ftb_tab #(
    .SETS(FTB_S1_SETS), .WAYS(FTB_S1_WAYS), .TAG_W(FTB_S1_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1)
  ) u_ftb1 (
    .clk, .rst_n, .rd_base(s1_base), .rd_hit(s1_raw.ftb_hit), .rd_ent(s1_raw.ent), .rd_ways(ftb1_ways_nc),
    .upd_en, .upd_base(upd_start), .upd_key_base('0), .upd_br,
    .upd_slot_valid(ftb1_sl_v), .upd_slot_idx(ftb1_sl_idx), .upd_slot_ctr(ftb1_sl_ctr_nc),
    .clr_en, .clr_base, .clr_pc
  );

  bpu_ftb_tage #(.N_ENT(FTB_S2_TAGE_N), .HAS_BASE(1'b1), .USE_LIVE_PRED(1'b0)) u_s2_tage (
    .clk, .rst_n, .rd_ix(s1_ix), .rd_raw(s1_raw.s2_tage_raw), .prefer_alt(s2_prefer_alt),
    .upd_en(upd_en && (upd_br.br_type == BR_DIRECT) && ftb1_sl_v),
    .upd_ix, .upd_sl(ftb1_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_pred_dir(upd_br.pred_dir), .upd_alt_pred(upd_br.alt_pred), .upd_pcpn(upd_br.pcpn),
    .upd_base_ctr(2'd0)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N)) u_s2_itt (
    .clk, .rst_n, .rd_ix(s1_ix), .rd_raw(s1_raw.itt_raw),
    .upd_en(upd_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir),
    .upd_ix, .upd_target(upd_br.target)
  );

  bpu_ftb_tab #(
    .SETS(FTB_AH_SETS), .WAYS(FTB_AH_WAYS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0)
  ) u_aftb (
    .clk, .rst_n, .rd_base(s0_base), .rd_hit(aftb_hit_nc), .rd_ent(aftb_ent_nc), .rd_ways(ah_rd_raw.ftb_ways),
    .upd_en(upd_en && upd_ah_v), .upd_base(upd_start), .upd_key_base(upd_ah_key_base), .upd_br,
    .upd_slot_valid(aftb_sl_v), .upd_slot_idx(aftb_sl_idx), .upd_slot_ctr(aftb_sl_ctr),
    .clr_en(1'b0), .clr_base('0), .clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH_TAGE_N), .HAS_BASE(1'b0), .USE_LIVE_PRED(1'b1)) u_atage (
    .clk, .rst_n, .rd_ix(ah_rd_ix), .rd_raw(ah_rd_raw.tage_raw), .prefer_alt(ah_prefer_alt),
    .upd_en(upd_en && upd_ah_v && (upd_br.br_type == BR_DIRECT) && aftb_sl_v),
    .upd_ix(upd_ah_ix), .upd_sl(aftb_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_pred_dir(1'b0), .upd_alt_pred(1'b0), .upd_pcpn(3'd0), .upd_base_ctr(aftb_sl_ctr)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N)) u_aitt (
    .clk, .rst_n, .rd_ix(ah_rd_ix), .rd_raw(ah_rd_raw.itt_raw),
    .upd_en(upd_en && upd_ah_v && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir),
    .upd_ix(upd_ah_ix), .upd_target(upd_br.target)
  );

endmodule

`default_nettype wire
