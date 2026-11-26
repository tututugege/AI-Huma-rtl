// Ref: front-end/BPU/BpuFtb.h & BPU_pipe.h
// v10 Unified Deep-Macro Multi-Bank 1RW BPU Predictor Arrays (ZERO N_RD replication, ZERO T0 SRAM reads!):
//   - u_ftb0:    16x4=64 FF cold-start uFTB (4x smaller than before)
//   - u_ftb1:    4096x4 = 4-Bank 1RW (256-deep -> 256x72 macros), Predict-wins + 1-entry WrBuf + WRBypass + PLRU
//   - u_s2_tage: 8-table 4096x4 = 8-Bank 1RW (512x64b -> 512x72 macros) + 4-Bank base, Write-wins not-hit + WRBypass
//   - u_s2_sc:   Bias 64x4x4 FF + 6 tables 2-Bank 1RW (GEHL 256x24b, IMLI/LOC 128x24b), Write-wins not-hit + WRBypass
//   - u_s2_itt:  3-table 256 = 2-Bank 1RW (128x52b), Write-wins not-hit
//   - u_aftb / u_aftb2:   2-Bank 1RW, Predict-wins + 1-entry WrBuf + WRBypass + PLRU
//   - u_atage / u_atage2: 2-Bank 1RW (512x60b / 256x60b), Write-wins not-hit + WRBypass
//   - u_aitt / u_aitt2:   2-Bank 1RW (128x52b), Write-wins not-hit
`default_nettype none

module bpu_ftb_arrays import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // S0 lookup (comb uFTB + sync 1RW 1-Ahead A & 2-Ahead B SRAM read; also reused on S3 ovr!)
  input  logic [XLEN_BITS-1:0] s0_base,
  input  logic [XLEN_BITS-1:0] s0_b_base,
  input  logic                 ah_rd_en,
  input  logic [XLEN_BITS-1:0] ah_rd_base,
  input  ftb_ix_t              ah_rd_ix1,
  input  ftb_ix_t              ah_rd_ix2,
  output logic                 ftb0_hit,
  output ftb_ent_t             ftb0_ent,
  output logic                 ftb0_b_hit,
  output ftb_ent_t             ftb0_b_ent,
  output ftb_ah_raw_t          ah_sram_raw,
  output ftb_ah_raw_t          ah2_sram_raw,
  output logic                 ah_prefer_alt,
  output logic                 ah2_prefer_alt,
  // S1 -> S2 lookup (ALL S2 tables launch together at S1 from r0_q; outputs arrive at S2)
  input  logic                 s1_valid,
  input  logic                 s1_b_valid,
  input  logic [XLEN_BITS-1:0] s1_base,
  input  logic [XLEN_BITS-1:0] s2_base,
  input  ftb_ix_t              s1_ix,
  input  ex_tage_ix_t          s1_ex_ix,
  input  sc_ix_t               s1_sc_ix,
  input  logic [XLEN_BITS-1:0] s1_b_base,
  input  logic [XLEN_BITS-1:0] s2_b_base,
  input  ftb_ix_t              s1_b_ix,
  input  ex_tage_ix_t          s1_b_ex_ix,
  input  sc_ix_t               s1_b_sc_ix,
  output logic                 s2_ftb_hit,
  output logic [1:0]           s2_ftb_way,
  output ftb_ent_t             s2_ftb_ent,
  output logic                 s2_b_ftb_hit,
  output logic [1:0]           s2_b_ftb_way,
  output ftb_ent_t             s2_b_ftb_ent,
  output ex_tage_raw_t         s2_tage_raw,
  output sc_raw_t              s2_sc_raw,
  output logic [7:0]           s2_sc_loc_idx,
  output ftb_itt_raw_t         s2_itt_raw,
  output ex_tage_raw_t         s2_b_tage_raw,
  output sc_raw_t              s2_b_sc_raw,
  output logic [7:0]           s2_b_sc_loc_idx,
  output ftb_itt_raw_t         s2_b_itt_raw,
  output logic [15:0][3:0]     s2_use_alt,
  output logic [15:0][5:0]     s2_sc_thres,
  // Single-cycle zero-T0-read commit update from bpu_ftb_brq (native 1.00 br/cyc!)
  input  logic                 upd_en,
  input  logic [XLEN_BITS-1:0] upd_start,
  input  ftb_ix_t              upd_ix,
  input  ex_tage_ix_t          upd_ex_ix,
  input  sc_ix_t               upd_sc_ix,
  input  logic                 upd_ah_v,
  input  logic                 upd_ah_kind, // 0 = 1-ahead A (aftb), 1 = 2-ahead B (aftb2)
  input  logic [XLEN_BITS-1:0] upd_ah_key_base,
  input  logic [XLEN_BITS-1:0] upd_ah_a_base,
  input  ftb_ix_t              upd_ah_ix1,
  input  ftb_ix_t              upd_ah_ix2,
  input  s2_pred_meta_t        upd_s2_meta,
  input  ah_pred_meta_t        upd_ah_meta,
  input  ftb_br_upd_t          upd_br,
  // Predecode false-branch slot clear
  input  logic                 clr_en,
  input  logic [XLEN_BITS-1:0] clr_base,
  input  logic [XLEN_BITS-1:0] clr_pc
);

  // ---- Predict read bank masks for Predict-Always-Wins FTB arrays & s2_base ----
  logic [BPU_FTB1_BANKS-1:0] ftb1_rd_mask;
  logic [BPU_AH1_BANKS-1:0]  ah1_ftb_rd_m;
  logic [BPU_AH2_BANKS-1:0]  ah2_ftb_rd_m;

  always_comb begin
    ftb1_rd_mask = '0;
    if (s1_valid) begin
      ftb1_rd_mask[s2_bank_of_pc(s1_base)] = 1'b1;
      if (s1_b_valid) ftb1_rd_mask[s2_bank_of_pc(s1_b_base)] = 1'b1;
    end
    ah1_ftb_rd_m = '0;
    ah2_ftb_rd_m = '0;
    if (ah_rd_en) begin
      ah1_ftb_rd_m[ah1_bank_of_pc(ah_rd_base)] = 1'b1;
      ah2_ftb_rd_m[ah2_bank_of_pc(ah_rd_base)] = 1'b1;
    end
  end

  // ---- Inter-module commit plan signals (combinational from upd_en + ftb_rec Meta + WRBypass) ----
  logic                  ftb1_sl_v, ftb1_any_v, aftb_sl_v, aftb2_sl_v;
  logic [FTB_SLOT_W-1:0] ftb1_sl_idx, aftb_sl_idx, aftb2_sl_idx;
  logic [1:0]            aftb_sl_ctr, aftb2_sl_ctr;

  logic                  s2_slot_meta_ok, ah1_slot_meta_ok, ah2_slot_meta_ok;
  logic                  s2_tage_upd_en, s2_itt_upd_en;
  logic                  upd_ah1_en, upd_ah2_en;
  logic                  ah1_tage_upd_en, ah2_tage_upd_en, ah1_itt_upd_en, ah2_itt_upd_en;

  assign s2_tage_upd_en  = upd_en && (upd_br.br_type == BR_DIRECT) && ftb1_any_v && ftb1_sl_v;
  assign s2_itt_upd_en   = upd_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir;
  assign upd_ah1_en      = upd_en && upd_ah_v && !upd_ah_kind;
  assign upd_ah2_en      = upd_en && upd_ah_v &&  upd_ah_kind;
  assign ah1_tage_upd_en = upd_ah1_en && (upd_br.br_type == BR_DIRECT) && aftb_sl_v;
  assign ah2_tage_upd_en = upd_ah2_en && (upd_br.br_type == BR_DIRECT) && aftb2_sl_v;
  assign ah1_itt_upd_en  = upd_ah1_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir;
  assign ah2_itt_upd_en  = upd_ah2_en && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir;

  assign s2_slot_meta_ok  = upd_s2_meta.ftb.hit &&
                            upd_s2_meta.ftb.ent.s[ftb1_sl_idx].valid &&
                            (upd_s2_meta.ftb.ent.s[ftb1_sl_idx].offset == upd_br.offset);
  assign ah1_slot_meta_ok = upd_ah_meta.ftb.hit &&
                            upd_ah_meta.ftb.ent.s[aftb_sl_idx].valid &&
                            (upd_ah_meta.ftb.ent.s[aftb_sl_idx].offset == upd_br.offset);
  assign ah2_slot_meta_ok = upd_ah_meta.ftb.hit &&
                            upd_ah_meta.ftb.ent.s[aftb2_sl_idx].valid &&
                            (upd_ah_meta.ftb.ent.s[aftb2_sl_idx].offset == upd_br.offset);

  // ---- Write-wins not-hit 1RW bank arbitration for TAGE / SC / ITT ----
  logic                  s2_base_wr_req, do_s2_base_wr;
  logic [EX_TN-1:0]      s2_tage_wr_mask;
  logic                  s2_sc_wr_en;
  logic [7:0]            s2_sc_wr_loc_idx, s1_sc_loc_a, s1_sc_loc_b;
  logic [NITT-1:0]       s2_itt_wr_mask, ah1_itt_wr_mask, ah2_itt_wr_mask;
  logic [TN-1:0]         ah1_tage_wr_mask, ah2_tage_wr_mask;

  logic [EX_TN-1:0]      s1_tage_sup_a, s1_tage_sup_b;
  logic [6:0]            s1_sc_sup_a, s1_sc_sup_b;
  logic [NITT-1:0]       s1_itt_sup_a, s1_itt_sup_b;
  logic [TN-1:0]         ah1_tage_sup, ah2_tage_sup;
  logic [NITT-1:0]       ah1_itt_sup, ah2_itt_sup;

  logic [EX_TN-1:0][BPU_S2_TAGE_BANKS-1:0] s2_tage_busy;
  logic [TN-1:0][BPU_AH1_BANKS-1:0]        ah1_tage_busy;
  logic [TN-1:0][BPU_AH2_BANKS-1:0]        ah2_tage_busy;

  assign do_s2_base_wr = !ftb1_rd_mask[upd_ex_ix.base_idx[1:0]];

  always_comb begin
    logic [6:0][BPU_SC_BANKS-1:0]   sc_busy;
    logic [NITT-1:0][BPU_ITT_BANKS-1:0] s2_itt_busy;
    logic [NITT-1:0][BPU_AH1_BANKS-1:0] ah1_itt_busy;
    logic [NITT-1:0][BPU_AH2_BANKS-1:0] ah2_itt_busy;

    s2_tage_busy = '0;
    sc_busy      = '0;
    s2_itt_busy  = '0;
    ah1_tage_busy = '0;
    ah2_tage_busy = '0;
    ah1_itt_busy  = '0;
    ah2_itt_busy  = '0;

    // 1. Mark write-occupied banks first (write-wins!)
    for (int k = 0; k < EX_TN; k++)
      if (s2_tage_wr_mask[k]) s2_tage_busy[k][upd_ex_ix.idx[k][2:0]] = 1'b1;

    if (s2_sc_wr_en) begin
      for (int g = 0; g < SC_GEHL_N; g++) sc_busy[1 + g][upd_sc_ix.gehl_idx[g][0]] = 1'b1;
      sc_busy[5][upd_sc_ix.imli_idx[0]] = 1'b1;
      sc_busy[6][s2_sc_wr_loc_idx[0]]   = 1'b1;
    end

    for (int k = 0; k < NITT; k++)
      if (s2_itt_wr_mask[k]) s2_itt_busy[k][upd_ix.idx[ITT_TBL[k]][0]] = 1'b1;

    for (int k = 0; k < TN; k++) begin
      if (ah1_tage_wr_mask[k]) ah1_tage_busy[k][upd_ah_ix1.idx[k][0]] = 1'b1;
      if (ah2_tage_wr_mask[k]) ah2_tage_busy[k][upd_ah_ix2.idx[k][0]] = 1'b1;
    end

    for (int k = 0; k < NITT; k++) begin
      if (ah1_itt_wr_mask[k]) ah1_itt_busy[k][upd_ah_ix1.idx[ITT_TBL[k]][0]] = 1'b1;
      if (ah2_itt_wr_mask[k]) ah2_itt_busy[k][upd_ah_ix2.idx[ITT_TBL[k]][0]] = 1'b1;
    end

    // 2. S1 Predict A (suppressed wherever write hits same bank; otherwise mark bank busy)
    s1_tage_sup_a = '0;
    s1_sc_sup_a   = '0;
    s1_itt_sup_a  = '0;
    s1_tage_sup_b = '0;
    s1_sc_sup_b   = '0;
    s1_itt_sup_b  = '0;

    if (s1_valid) begin
      for (int k = 0; k < EX_TN; k++) begin
        if (s2_tage_busy[k][s1_ex_ix.idx[k][2:0]]) s1_tage_sup_a[k] = 1'b1;
        else                                       s2_tage_busy[k][s1_ex_ix.idx[k][2:0]] = 1'b1;
      end
      for (int g = 0; g < SC_GEHL_N; g++) begin
        if (sc_busy[1 + g][s1_sc_ix.gehl_idx[g][0]]) s1_sc_sup_a[1 + g] = 1'b1;
        else                                         sc_busy[1 + g][s1_sc_ix.gehl_idx[g][0]] = 1'b1;
      end
      if (sc_busy[5][s1_sc_ix.imli_idx[0]]) s1_sc_sup_a[5] = 1'b1;
      else                                  sc_busy[5][s1_sc_ix.imli_idx[0]] = 1'b1;
      if (sc_busy[6][s1_sc_loc_a[0]]) s1_sc_sup_a[6] = 1'b1;
      else                            sc_busy[6][s1_sc_loc_a[0]] = 1'b1;
      for (int k = 0; k < NITT; k++) begin
        if (s2_itt_busy[k][s1_ix.idx[ITT_TBL[k]][0]]) s1_itt_sup_a[k] = 1'b1;
        else                                          s2_itt_busy[k][s1_ix.idx[ITT_TBL[k]][0]] = 1'b1;
      end

      // 3. S1 Predict B (suppressed wherever write OR Predict A hits same bank)
      if (s1_b_valid) begin
        for (int k = 0; k < EX_TN; k++) begin
          if (s2_tage_busy[k][s1_b_ex_ix.idx[k][2:0]]) s1_tage_sup_b[k] = 1'b1;
          else                                         s2_tage_busy[k][s1_b_ex_ix.idx[k][2:0]] = 1'b1;
        end
        for (int g = 0; g < SC_GEHL_N; g++) begin
          if (sc_busy[1 + g][s1_b_sc_ix.gehl_idx[g][0]]) s1_sc_sup_b[1 + g] = 1'b1;
          else                                           sc_busy[1 + g][s1_b_sc_ix.gehl_idx[g][0]] = 1'b1;
        end
        if (sc_busy[5][s1_b_sc_ix.imli_idx[0]]) s1_sc_sup_b[5] = 1'b1;
        else                                    sc_busy[5][s1_b_sc_ix.imli_idx[0]] = 1'b1;
        if (sc_busy[6][s1_sc_loc_b[0]]) s1_sc_sup_b[6] = 1'b1;
        else                            sc_busy[6][s1_sc_loc_b[0]] = 1'b1;
        for (int k = 0; k < NITT; k++) begin
          if (s2_itt_busy[k][s1_b_ix.idx[ITT_TBL[k]][0]]) s1_itt_sup_b[k] = 1'b1;
          else                                            s2_itt_busy[k][s1_b_ix.idx[ITT_TBL[k]][0]] = 1'b1;
        end
      end
    end

    // 4. S0 Ahead 1 & 2 reads
    ah1_tage_sup = '0;
    ah2_tage_sup = '0;
    ah1_itt_sup  = '0;
    ah2_itt_sup  = '0;
    if (ah_rd_en) begin
      for (int k = 0; k < TN; k++) begin
        if (ah1_tage_busy[k][ah_rd_ix1.idx[k][0]]) ah1_tage_sup[k] = 1'b1;
        else                                       ah1_tage_busy[k][ah_rd_ix1.idx[k][0]] = 1'b1;
        if (ah2_tage_busy[k][ah_rd_ix2.idx[k][0]]) ah2_tage_sup[k] = 1'b1;
        else                                       ah2_tage_busy[k][ah_rd_ix2.idx[k][0]] = 1'b1;
      end
      for (int k = 0; k < NITT; k++) begin
        if (ah1_itt_busy[k][ah_rd_ix1.idx[ITT_TBL[k]][0]]) ah1_itt_sup[k] = 1'b1;
        else                                               ah1_itt_busy[k][ah_rd_ix1.idx[ITT_TBL[k]][0]] = 1'b1;
        if (ah2_itt_busy[k][ah_rd_ix2.idx[ITT_TBL[k]][0]]) ah2_itt_sup[k] = 1'b1;
        else                                               ah2_itt_busy[k][ah_rd_ix2.idx[ITT_TBL[k]][0]] = 1'b1;
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  ftb_ent_t [FTB_S0_WAYS-1:0] ftb0_ways_nc;
  ftb_ent_t [FTB_S1_WAYS-1:0] ftb1_ways_nc;
  logic [FTB_S0_WAYS-1:0][FTB_VA_BITS-1:0] ftb0_bb_nc;
  logic [FTB_S1_WAYS-1:0][FTB_VA_BITS-1:0] ftb1_bb_nc;
  logic [FTB_AH_WAYS-1:0][FTB_VA_BITS-1:0] aftb_bb_nc;
  logic                       ftb0_sl_v_nc, ftb0_any_v_nc, aftb_hit_nc, aftb2_hit_nc, aftb_any_v_nc, aftb2_any_v_nc;
  logic                       aftb_rd2_hit_nc, aftb2_rd2_hit_nc;
  logic [1:0]                 ftb0_w_nc, ftb0_w2_nc, ftb0_sl_idx_nc, ftb0_sl_ctr_nc, ftb1_sl_ctr_nc;
  logic [2:0]                 aftb_w_nc, aftb_w2_nc, aftb2_w_nc, aftb2_w2_nc;
  ftb_ent_t                   aftb_ent_nc, aftb2_ent_nc, aftb_rd2_ent_nc, aftb2_rd2_ent_nc;
  ftb_itt_raw_t               aitt_rd2_nc, aitt2_rd2_nc;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- Tiny S0 uFTB (16x4=64 FF) ----
  bpu_ftb_tab #(
    .SETS(FTB_S0_SETS), .WAYS(FTB_S0_WAYS), .NB(1), .TAG_W(FTB_S0_TAG_W), .TGT_BITS(FTB_S0_TGT_B),
    .ALLOC_ONLY_TAKEN(1'b1), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .HAS_RD2(1'b1), .USE_SRAM(1'b0)
  ) u_ftb0 (
    .clk, .rst_n,
    .rd_en(1'b1), .rd_base(s0_base), .rd_cmp_base(s0_base),
    .rd_hit(ftb0_hit), .rd_way(ftb0_w_nc), .rd_ent(ftb0_ent), .rd_ways(ftb0_ways_nc), .rd_b_base(ftb0_bb_nc),
    .rd2_en(1'b1), .rd2_base(s0_b_base), .rd2_cmp_base(s0_b_base),
    .rd2_hit(ftb0_b_hit), .rd2_way(ftb0_w2_nc), .rd2_ent(ftb0_b_ent),
    .upd_en(upd_en), .upd_base(upd_start), .upd_key_base('0), .upd_b_base('0), .upd_br(upd_br),
    .upd_meta_hit(1'b0), .upd_meta_way(2'd0), .upd_meta_ent('0), .rd_bank_mask(1'b0),
    .upd_slot_valid(ftb0_sl_v_nc), .upd_slot_idx(ftb0_sl_idx_nc), .upd_slot_ctr(ftb0_sl_ctr_nc), .upd_any_v(ftb0_any_v_nc),
    .clr_en(clr_en), .clr_base(clr_base), .clr_pc(clr_pc)
  );

  // ---- Main FTB1 (1024x4 = 4-Bank 256-deep 1RW, Predict-wins + 1-entry WrBuf + WRBypass + PLRU) ----
  bpu_ftb_tab #(
    .SETS(FTB_S1_SETS), .WAYS(FTB_S1_WAYS), .NB(BPU_FTB1_BANKS), .TAG_W(FTB_S1_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b0), .HAS_CLR(1'b1), .HAS_RD2(1'b1),
    .USE_SRAM(1'b1), .TAG("BPU_FTB1")
  ) u_ftb1 (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_base(s1_base), .rd_cmp_base(s2_base),
    .rd_hit(s2_ftb_hit), .rd_way(s2_ftb_way), .rd_ent(s2_ftb_ent), .rd_ways(ftb1_ways_nc), .rd_b_base(ftb1_bb_nc),
    .rd2_en(s1_valid && s1_b_valid), .rd2_base(s1_b_base), .rd2_cmp_base(s2_b_base),
    .rd2_hit(s2_b_ftb_hit), .rd2_way(s2_b_ftb_way), .rd2_ent(s2_b_ftb_ent),
    .upd_en(upd_en), .upd_base(upd_start), .upd_key_base('0), .upd_b_base('0), .upd_br(upd_br),
    .upd_meta_hit(upd_s2_meta.ftb.hit), .upd_meta_way(upd_s2_meta.ftb.way), .upd_meta_ent(upd_s2_meta.ftb.ent),
    .rd_bank_mask(ftb1_rd_mask),
    .upd_slot_valid(ftb1_sl_v), .upd_slot_idx(ftb1_sl_idx), .upd_slot_ctr(ftb1_sl_ctr_nc), .upd_any_v(ftb1_any_v),
    .clr_en(clr_en), .clr_base(clr_base), .clr_pc(clr_pc)
  );

  // ---- S2 8-table ExBlockTage (8-Bank 512x64b 1RW + 4-Bank 1024x8b base, Zero T0 Read) ----
  logic       s2_upd_pred, s2_upd_prov_hit;
  logic [2:0] s2_upd_prov_cnt;
  logic [1:0] s2_upd_base_cnt;

  bpu_ftb_ex_tage u_s2_tage (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_sup(s1_tage_sup_a),
    .rd2_en(s1_valid && s1_b_valid), .rd2_sup(s1_tage_sup_b),
    .rd_ix(s1_ex_ix), .rd2_ix(s1_b_ex_ix),
    .rd_raw(s2_tage_raw), .rd2_raw(s2_b_tage_raw),
    .use_alt_o(s2_use_alt),
    .upd_en(s2_tage_upd_en), .upd_ix(upd_ex_ix), .upd_sl(ftb1_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_meta_valid(s2_slot_meta_ok), .upd_meta(upd_s2_meta.tage[ftb1_sl_idx]),
    .do_base_wr(do_s2_base_wr),
    .base_wr_req_o(s2_base_wr_req),
    .tbl_wr_mask_o(s2_tage_wr_mask),
    .tbl_busy_mask(s2_tage_busy),
    .upd_pred_o(s2_upd_pred), .upd_prov_hit_o(s2_upd_prov_hit),
    .upd_prov_cnt_o(s2_upd_prov_cnt), .upd_base_cnt_o(s2_upd_base_cnt)
  );

  // ---- S2 Statistical Corrector (FF Bias + 2-Bank 1RW GEHL/IMLI/LOC, Zero T0 Read) ----
  bpu_ftb_sc u_s2_sc (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_sup(s1_sc_sup_a),
    .rd2_en(s1_valid && s1_b_valid), .rd2_sup(s1_sc_sup_b),
    .rd_ix(s1_sc_ix), .rd2_ix(s1_b_sc_ix),
    .rd_loc_idx_comb_o(s1_sc_loc_a), .rd2_loc_idx_comb_o(s1_sc_loc_b),
    .rd_raw(s2_sc_raw), .rd_loc_idx_q_o(s2_sc_loc_idx),
    .rd2_raw(s2_b_sc_raw), .rd2_loc_idx_q_o(s2_b_sc_loc_idx),
    .thres_o(s2_sc_thres),
    .upd_en(s2_tage_upd_en), .upd_ix(upd_sc_ix), .upd_sl(ftb1_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_tage_pred(s2_upd_pred), .upd_prov_hit(s2_upd_prov_hit),
    .upd_prov_cnt(s2_upd_prov_cnt), .upd_base_cnt(s2_upd_base_cnt),
    .upd_meta_valid(s2_slot_meta_ok), .upd_meta(upd_s2_meta.sc),
    .wr_en_o(s2_sc_wr_en), .wr_loc_idx_o(s2_sc_wr_loc_idx)
  );

  // ---- S2 ITT (2-Bank 128x52b 1RW, Zero T0 Read) ----
  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .NB(BPU_ITT_BANKS), .HAS_RD2(1'b1), .TAG("BPU_S2_ITT")) u_s2_itt (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_sup(s1_itt_sup_a),
    .rd2_en(s1_valid && s1_b_valid), .rd2_sup(s1_itt_sup_b),
    .rd_ix(s1_ix), .rd2_ix(s1_b_ix), .rd_raw(s2_itt_raw), .rd2_raw(s2_b_itt_raw),
    .upd_en(s2_itt_upd_en), .upd_ix(upd_ix), .upd_target(upd_br.target), .upd_meta(upd_s2_meta.itt),
    .wr_mask_o(s2_itt_wr_mask)
  );

  // ---- 1-Ahead A arrays (2-Bank 1RW: aftb 128-deep, atage 512x60b, aitt 128x52b) ----
  assign ah_sram_raw.b_base = '0;

  bpu_ftb_tab #(
    .SETS(FTB_AH_SETS), .WAYS(FTB_AH_WAYS), .NB(BPU_AH1_BANKS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .HAS_RD2(1'b0), .STORE_B_BASE(1'b0),
    .USE_SRAM(1'b1), .TAG("BPU_AFTB")
  ) u_aftb (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_base(ah_rd_base), .rd_cmp_base('0),
    .rd_hit(aftb_hit_nc), .rd_way(aftb_w_nc), .rd_ent(aftb_ent_nc), .rd_ways(ah_sram_raw.ftb_ways), .rd_b_base(aftb_bb_nc),
    .rd2_en(1'b0), .rd2_base('0), .rd2_cmp_base('0), .rd2_hit(aftb_rd2_hit_nc), .rd2_way(aftb_w2_nc), .rd2_ent(aftb_rd2_ent_nc),
    .upd_en(upd_ah1_en), .upd_base(upd_start), .upd_key_base(upd_ah_key_base), .upd_b_base('0), .upd_br(upd_br),
    .upd_meta_hit(upd_ah_meta.ftb.hit), .upd_meta_way(upd_ah_meta.ftb.way), .upd_meta_ent(upd_ah_meta.ftb.ent),
    .rd_bank_mask(ah1_ftb_rd_m),
    .upd_slot_valid(aftb_sl_v), .upd_slot_idx(aftb_sl_idx), .upd_slot_ctr(aftb_sl_ctr), .upd_any_v(aftb_any_v_nc),
    .clr_en(1'b0), .clr_base('0), .clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH_TAGE_N), .NB(BPU_AH1_BANKS), .TAG("BPU_ATAGE")) u_atage (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah1_tage_sup), .rd_ix(ah_rd_ix1), .rd_raw(ah_sram_raw.tage_raw),
    .prefer_alt(ah_prefer_alt),
    .upd_en(ah1_tage_upd_en), .upd_ix(upd_ah_ix1), .upd_sl(aftb_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_base_ctr(aftb_sl_ctr), .upd_meta_valid(ah1_slot_meta_ok), .upd_meta(upd_ah_meta.tage[aftb_sl_idx]),
    .tbl_wr_mask_o(ah1_tage_wr_mask),
    .tbl_busy_mask(ah1_tage_busy)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .NB(BPU_AH1_BANKS), .HAS_RD2(1'b0), .TAG("BPU_AITT")) u_aitt (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah1_itt_sup), .rd2_en(1'b0), .rd2_sup('0),
    .rd_ix(ah_rd_ix1), .rd2_ix('0), .rd_raw(ah_sram_raw.itt_raw), .rd2_raw(aitt_rd2_nc),
    .upd_en(ah1_itt_upd_en), .upd_ix(upd_ah_ix1), .upd_target(upd_br.target), .upd_meta(upd_ah_meta.itt),
    .wr_mask_o(ah1_itt_wr_mask)
  );

  // ---- 2-Ahead B companion arrays (2-Bank 1RW: aftb2 64-deep + b_base, atage2 256x60b, aitt2 128x52b) ----
  bpu_ftb_tab #(
    .SETS(FTB_AH2_SETS), .WAYS(FTB_AH2_WAYS), .NB(BPU_AH2_BANKS), .TAG_W(FTB_AH_TAG_W), .TGT_BITS(0),
    .ALLOC_ONLY_TAKEN(1'b0), .AHEAD_MODE(1'b1), .HAS_CLR(1'b0), .HAS_RD2(1'b0), .STORE_B_BASE(1'b1),
    .USE_SRAM(1'b1), .TAG("BPU_AFTB2")
  ) u_aftb2 (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_base(ah_rd_base), .rd_cmp_base('0),
    .rd_hit(aftb2_hit_nc), .rd_way(aftb2_w_nc), .rd_ent(aftb2_ent_nc), .rd_ways(ah2_sram_raw.ftb_ways), .rd_b_base(ah2_sram_raw.b_base),
    .rd2_en(1'b0), .rd2_base('0), .rd2_cmp_base('0), .rd2_hit(aftb2_rd2_hit_nc), .rd2_way(aftb2_w2_nc), .rd2_ent(aftb2_rd2_ent_nc),
    .upd_en(upd_ah2_en), .upd_base(upd_ah_a_base), .upd_key_base(upd_ah_key_base), .upd_b_base(upd_start), .upd_br(upd_br),
    .upd_meta_hit(upd_ah_meta.ftb.hit), .upd_meta_way(upd_ah_meta.ftb.way), .upd_meta_ent(upd_ah_meta.ftb.ent),
    .rd_bank_mask(ah2_ftb_rd_m),
    .upd_slot_valid(aftb2_sl_v), .upd_slot_idx(aftb2_sl_idx), .upd_slot_ctr(aftb2_sl_ctr), .upd_any_v(aftb2_any_v_nc),
    .clr_en(1'b0), .clr_base('0), .clr_pc('0)
  );

  bpu_ftb_tage #(.N_ENT(FTB_AH2_TAGE_N), .NB(BPU_AH2_BANKS), .TAG("BPU_ATAGE2")) u_atage2 (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah2_tage_sup), .rd_ix(ah_rd_ix2), .rd_raw(ah2_sram_raw.tage_raw),
    .prefer_alt(ah2_prefer_alt),
    .upd_en(ah2_tage_upd_en), .upd_ix(upd_ah_ix2), .upd_sl(aftb2_sl_idx), .upd_real_dir(upd_br.actual_dir),
    .upd_base_ctr(aftb2_sl_ctr), .upd_meta_valid(ah2_slot_meta_ok), .upd_meta(upd_ah_meta.tage[aftb2_sl_idx]),
    .tbl_wr_mask_o(ah2_tage_wr_mask),
    .tbl_busy_mask(ah2_tage_busy)
  );

  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .NB(BPU_AH2_BANKS), .HAS_RD2(1'b0), .TAG("BPU_AITT2")) u_aitt2 (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah2_itt_sup), .rd2_en(1'b0), .rd2_sup('0),
    .rd_ix(ah_rd_ix2), .rd2_ix('0), .rd_raw(ah2_sram_raw.itt_raw), .rd2_raw(aitt2_rd2_nc),
    .upd_en(ah2_itt_upd_en), .upd_ix(upd_ah_ix2), .upd_target(upd_br.target), .upd_meta(upd_ah_meta.itt),
    .wr_mask_o(ah2_itt_wr_mask)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_arr;
  assign unused_arr = ^{s2_base_wr_req, upd_ix.base_idx, upd_ix.idx[0], upd_ix.tag[0],
                        upd_ah_ix1.base_idx, upd_ah_ix2.base_idx,
                        s2_sc_wr_loc_idx[7:1], s1_sc_loc_a[7:1], s1_sc_loc_b[7:1]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
