// Ref: front-end/BPU/BpuFtb.h & BPU_pipe.h
// Clean BPU v11 Predictor Arrays (7 clean tables, single-block 1-Taken, deep Multi-Bank 1RW SRAM, ZERO T0 reads):
//   - u_ftb0:    16x4=64 FF cold-start uFTB (bpu_uftb.sv)
//   - u_ftb1:    4096x4 = 2-Bank 1RW (512x4w, 215b/way -> 24 x 512x72 macros), Predict-wins + WrBuf + WRBypass + PLRU
//   - u_s2_tage: 6-table 4096x4 = 8-Bank 1RW (48 x 512x72 macros) + 4-Bank Base (8 x 512x8), Write-wins not-hit + WRBypass
//   - u_s2_itt:  3-table 256 = 2-Bank 1RW (6 x 128x64 macros), Write-wins not-hit
//   - u_aftb:    2048x8 = 2-Bank 1RW (128x8w), Predict-wins + WrBuf + WRBypass + PLRU
//   - u_atage:   4-table 1024x4 = 2-Bank 1RW (8 x 512x72 macros), Write-wins not-hit + WRBypass
//   - u_aitt:    3-table 256 = 2-Bank 1RW (6 x 128x64 macros), Write-wins not-hit
`default_nettype none

module bpu_ftb_arrays import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // S0 lookup (comb uFTB + sync 1RW 1-Ahead A SRAM read; also reused on ovr_pend_q!)
  input  logic [XLEN_BITS-1:0] s0_base,
  input  logic                 ah_rd_en,
  input  logic [XLEN_BITS-1:0] ah_rd_base,
  input  ftb_ix_t              ah_rd_ix,
  output logic                 ftb0_hit,
  output ftb_ent_t             ftb0_ent,
  output ftb_ah_raw_t          ah_sram_raw,
  output logic                 ah_prefer_alt,
  // S1 -> S2 lookup (single-block exact-PC 1RW SRAM read launched at S1 from r0_q; arrives at S2)
  input  logic                 s1_valid,
  input  logic [XLEN_BITS-1:0] s1_base,
  input  logic [XLEN_BITS-1:0] s2_base,
  input  ftb_ix_t              s1_ix,
  input  ex_tage_ix_t          s1_ex_ix,
  output logic                 s2_ftb_hit,
  output logic [1:0]           s2_ftb_way,
  output ftb_ent_t             s2_ftb_ent,
  output ex_tage_raw_t         s2_tage_raw,
  output ftb_itt_raw_t         s2_itt_raw,
  output logic [15:0][3:0]     s2_use_alt,
  // Single-cycle zero-T0-read commit update from bpu_ftb_brq (native 1.00 br/cyc!)
  input  logic                 upd_en,
  input  logic [XLEN_BITS-1:0] upd_start,
  input  ftb_ix_t              upd_ix,
  input  ex_tage_ix_t          upd_ex_ix,
  input  logic                 upd_ah_v,
  input  logic [XLEN_BITS-1:0] upd_ah_key_base,
  input  ftb_ix_t              upd_ah_ix,
  input  s2_pred_meta_t        upd_s2_meta,
  input  ah_pred_meta_t        upd_ah_meta,
  input  ftb_br_upd_t          upd_br,
  // Predecode false-branch slot clear
  input  logic                 clr_en,
  input  logic [XLEN_BITS-1:0] clr_base,
  input  logic [XLEN_BITS-1:0] clr_pc
);

  // ---- Predict read bank masks for Predict-Always-Wins FTB arrays & s2_base ----
  logic [BPU_FTB1_BANKS-1:0]    ftb1_rd_mask;
  logic [BPU_AH1_BANKS-1:0]     ah1_ftb_rd_m;
  logic [BPU_S2_BASE_BANKS-1:0] s2_base_rd_mask;

  always_comb begin
    ftb1_rd_mask    = '0;
    s2_base_rd_mask = '0;
    if (s1_valid) begin
      ftb1_rd_mask[s2_bank_of_pc(s1_base)]       = 1'b1;
      s2_base_rd_mask[s1_ex_ix.base_idx[1:0]]   = 1'b1;
    end
    ah1_ftb_rd_m = '0;
    if (ah_rd_en) begin
      ah1_ftb_rd_m[ah1_bank_of_pc(ah_rd_base)]  = 1'b1;
    end
  end

  // ---- Inter-module commit plan signals ----
  logic                  ftb1_sl_v, ftb1_any_v, aftb_sl_v;
  logic [FTB_SLOT_W-1:0] ftb1_sl_idx, aftb_sl_idx;
  logic [1:0]            aftb_sl_ctr;

  logic                  s2_slot_meta_ok, ah1_slot_meta_ok;
  logic                  s2_tage_upd_en, s2_itt_upd_en;
  logic                  upd_ah1_en, ah1_tage_upd_en, ah1_itt_upd_en;

  assign s2_tage_upd_en  = upd_en && (upd_br.br_type == BR_DIRECT) && ftb1_any_v && ftb1_sl_v;
  assign s2_itt_upd_en   = upd_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir;
  assign upd_ah1_en      = upd_en && upd_ah_v;
  assign ah1_tage_upd_en = upd_ah1_en && (upd_br.br_type == BR_DIRECT) && aftb_sl_v;
  assign ah1_itt_upd_en  = upd_ah1_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir;

  assign s2_slot_meta_ok  = upd_s2_meta.ftb.hit &&
                            upd_s2_meta.ftb.ent.s[ftb1_sl_idx].valid &&
                            (upd_s2_meta.ftb.ent.s[ftb1_sl_idx].offset == upd_br.offset);
  assign ah1_slot_meta_ok = upd_ah_meta.ftb.hit &&
                            upd_ah_meta.ftb.ent.s[aftb_sl_idx].valid &&
                            (upd_ah_meta.ftb.ent.s[aftb_sl_idx].offset == upd_br.offset);

  // ---- Write-wins not-hit 1RW bank arbitration for TAGE / ITT ----
  logic                  do_s2_base_wr;
  logic [EX_TN-1:0]      s2_tage_wr_mask, s1_tage_sup;
  logic [NITT-1:0]       s2_itt_wr_mask, s1_itt_sup;
  logic [TN-1:0]         ah1_tage_wr_mask, ah1_tage_sup;
  logic [NITT-1:0]       ah1_itt_wr_mask, ah1_itt_sup;

  logic [EX_TN-1:0][BPU_S2_TAGE_BANKS-1:0] s2_tage_busy;
  logic [TN-1:0][BPU_AH1_BANKS-1:0]        ah1_tage_busy;

  assign do_s2_base_wr = !s2_base_rd_mask[upd_ex_ix.base_idx[1:0]];

  always_comb begin
    logic [NITT-1:0][BPU_ITT_BANKS-1:0] s2_itt_busy;
    logic [NITT-1:0][BPU_AH1_BANKS-1:0] ah1_itt_busy;

    s2_tage_busy  = '0;
    s2_itt_busy   = '0;
    ah1_tage_busy = '0;
    ah1_itt_busy  = '0;

    // 1. Mark write-occupied banks first (write-wins!)
    for (int k = 0; k < EX_TN; k++)
      if (s2_tage_wr_mask[k]) s2_tage_busy[k][upd_ex_ix.idx[k][2:0]] = 1'b1;

    for (int k = 0; k < NITT; k++)
      if (s2_itt_wr_mask[k]) s2_itt_busy[k][upd_ix.idx[ITT_TBL[k]][0]] = 1'b1;

    for (int k = 0; k < TN; k++)
      if (ah1_tage_wr_mask[k]) ah1_tage_busy[k][upd_ah_ix.idx[k][0]] = 1'b1;

    for (int k = 0; k < NITT; k++)
      if (ah1_itt_wr_mask[k]) ah1_itt_busy[k][upd_ah_ix.idx[ITT_TBL[k]][0]] = 1'b1;

    // 2. S1 Predict (suppressed wherever write hits same bank; otherwise mark bank busy)
    s1_tage_sup = '0;
    s1_itt_sup  = '0;
    if (s1_valid) begin
      for (int k = 0; k < EX_TN; k++) begin
        if (s2_tage_busy[k][s1_ex_ix.idx[k][2:0]]) s1_tage_sup[k] = 1'b1;
        else                                      s2_tage_busy[k][s1_ex_ix.idx[k][2:0]] = 1'b1;
      end
      for (int k = 0; k < NITT; k++) begin
        if (s2_itt_busy[k][s1_ix.idx[ITT_TBL[k]][0]]) s1_itt_sup[k] = 1'b1;
        else                                          s2_itt_busy[k][s1_ix.idx[ITT_TBL[k]][0]] = 1'b1;
      end
    end

    // 3. S0 1-Ahead A read
    ah1_tage_sup = '0;
    ah1_itt_sup  = '0;
    if (ah_rd_en) begin
      for (int k = 0; k < TN; k++) begin
        if (ah1_tage_busy[k][ah_rd_ix.idx[k][0]]) ah1_tage_sup[k] = 1'b1;
        else                                      ah1_tage_busy[k][ah_rd_ix.idx[k][0]] = 1'b1;
      end
      for (int k = 0; k < NITT; k++) begin
        if (ah1_itt_busy[k][ah_rd_ix.idx[ITT_TBL[k]][0]]) ah1_itt_sup[k] = 1'b1;
        else                                              ah1_itt_busy[k][ah_rd_ix.idx[ITT_TBL[k]][0]] = 1'b1;
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  ftb_ent_t [FTB_S1_WAYS-1:0] ftb1_ways_nc;
  logic                       aftb_hit_nc, aftb_any_v_nc;
  logic [1:0]                 ftb1_sl_ctr_nc;
  logic [2:0]                 aftb_w_nc;
  ftb_ent_t                   aftb_ent_nc;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- 1. Tiny S0 uFTB (16x4 = 64 FF) ----
  bpu_uftb u_ftb0 (
    .clk, .rst_n,
    .rd_base(s0_base), .rd_hit(ftb0_hit), .rd_ent(ftb0_ent),
    .upd_en(upd_en), .upd_base(upd_start), .upd_br(upd_br),
    .clr_en(clr_en), .clr_base(clr_base), .clr_pc(clr_pc)
  );

  // ---- 2. Main FTB1 (1024x4 = 2-Bank 512x4w 1RW, 215b/way -> 24 x 512x72 macros) ----
  bpu_ftb_tab #(
    .SETS(FTB_S1_SETS), .WAYS(FTB_S1_WAYS), .NB(BPU_FTB1_BANKS), .TAG_W(FTB_S1_TAG_W),
    .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .TAG("BPU_FTB1")
  ) u_ftb1 (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_base(s1_base), .rd_cmp_base(s2_base),
    .rd_hit(s2_ftb_hit), .rd_way(s2_ftb_way), .rd_ent(s2_ftb_ent), .rd_ways(ftb1_ways_nc),
    .upd_en(upd_en), .upd_base(upd_start), .upd_key_base('0), .upd_br(upd_br),
    .upd_meta_hit(upd_s2_meta.ftb.hit), .upd_meta_way(upd_s2_meta.ftb.way), .upd_meta_ent(upd_s2_meta.ftb.ent),
    .rd_bank_mask(ftb1_rd_mask),
    .upd_slot_valid(ftb1_sl_v), .upd_slot_idx(ftb1_sl_idx), .upd_slot_ctr(ftb1_sl_ctr_nc), .upd_any_v(ftb1_any_v),
    .clr_en(clr_en), .clr_base(clr_base), .clr_pc(clr_pc)
  );

  // ---- 3. S2 6-table ExBlockTage (8-Bank 512x64b + 4-Bank 1024x8b Base 1RW) ----
  bpu_ftb_ex_tage u_s2_tage (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_sup(s1_tage_sup), .rd_ix(s1_ex_ix),
    .rd_raw(s2_tage_raw), .use_alt_o(s2_use_alt),
    .upd_en(s2_tage_upd_en), .upd_ix(upd_ex_ix), .upd_sl(ftb1_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_meta_valid(s2_slot_meta_ok), .upd_meta(upd_s2_meta.tage[ftb1_sl_idx]),
    .do_base_wr(do_s2_base_wr),
    .tbl_wr_mask_o(s2_tage_wr_mask),
    .tbl_busy_mask(s2_tage_busy)
  );

  // ---- 4. S2 ITT (3-table 2-Bank 128x52b 1RW) ----
  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .NB(BPU_ITT_BANKS), .HOLD_RD0(1'b0), .TAG("BPU_S2_ITT")) u_s2_itt (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_sup(s1_itt_sup), .rd_ix(s1_ix), .rd_raw(s2_itt_raw),
    .upd_en(s2_itt_upd_en), .upd_ix(upd_ix), .upd_target(upd_br.target), .upd_meta(upd_s2_meta.itt),
    .wr_mask_o(s2_itt_wr_mask)
  );

  // ---- 5..7. 1-Ahead A arrays (2-Bank 1RW: aftb 128x8w, atage 512x60b, aitt 128x52b) ----
  bpu_ftb_tab #(
    .SETS(FTB_AH_SETS), .WAYS(FTB_AH_WAYS), .NB(BPU_AH1_BANKS), .TAG_W(FTB_AH_TAG_W),
    .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .TAG("BPU_AFTB")
  ) u_aftb (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_base(ah_rd_base), .rd_cmp_base('0),
    .rd_hit(aftb_hit_nc), .rd_way(aftb_w_nc), .rd_ent(aftb_ent_nc), .rd_ways(ah_sram_raw.ftb_ways),
    .upd_en(upd_ah1_en), .upd_base(upd_start), .upd_key_base(upd_ah_key_base), .upd_br(upd_br),
    .upd_meta_hit(upd_ah_meta.ftb.hit), .upd_meta_way(upd_ah_meta.ftb.way), .upd_meta_ent(upd_ah_meta.ftb.ent),
    .rd_bank_mask(ah1_ftb_rd_m),
    .upd_slot_valid(aftb_sl_v), .upd_slot_idx(aftb_sl_idx), .upd_slot_ctr(aftb_sl_ctr), .upd_any_v(aftb_any_v_nc),
    .clr_en(1'b0), .clr_base('0), .clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH_TAGE_N), .NB(BPU_AH1_BANKS), .TAG("BPU_ATAGE")) u_atage (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah1_tage_sup), .rd_ix(ah_rd_ix), .rd_raw(ah_sram_raw.tage_raw),
    .prefer_alt(ah_prefer_alt),
    .upd_en(ah1_tage_upd_en), .upd_ix(upd_ah_ix), .upd_sl(aftb_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_base_ctr(aftb_sl_ctr), .upd_meta_valid(ah1_slot_meta_ok), .upd_meta(upd_ah_meta.tage[aftb_sl_idx]),
    .tbl_wr_mask_o(ah1_tage_wr_mask),
    .tbl_busy_mask(ah1_tage_busy)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .NB(BPU_AH1_BANKS), .HOLD_RD0(1'b1), .TAG("BPU_AITT")) u_aitt (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah1_itt_sup), .rd_ix(ah_rd_ix), .rd_raw(ah_sram_raw.itt_raw),
    .upd_en(ah1_itt_upd_en), .upd_ix(upd_ah_ix), .upd_target(upd_br.target), .upd_meta(upd_ah_meta.itt),
    .wr_mask_o(ah1_itt_wr_mask)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_arr;
  assign unused_arr = ^{upd_ix.base_idx, upd_ix.idx[0], upd_ix.tag[0], upd_ah_ix.base_idx};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
