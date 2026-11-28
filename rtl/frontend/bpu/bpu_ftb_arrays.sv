// Ref: front-end/BPU/BpuFtb.h & BPU_pipe.h  (Single-Set 4 arrays: u_ftb0, u_ftb1, u_ah_ex_tage, u_aitt)
`default_nettype none

module bpu_ftb_arrays import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // S0 uFTB + A0 2-Ahead 1RW SRAM read launch
  input  logic [XLEN_BITS-1:0]    s0_base,
  input  logic                    ah_rd_en,
  input  ex_tage_ix_t             ah_rd_ex_ix,
  input  itt_ix_t                 ah_rd_itt_ix,
  output logic                    ftb0_hit,
  output ftb_ent_t                ftb0_ent,
  output ftb_ah_raw_t             ah_sram_raw,
  output logic [15:0][3:0]        ah_use_alt,
  // S1 -> S2 Main FTB1 1RW SRAM read
  input  logic                    s1_valid,
  input  logic [XLEN_BITS-1:0]    s1_base,
  input  logic [XLEN_BITS-1:0]    s2_base,
  output logic                    s2_ftb_hit,
  output logic [1:0]              s2_ftb_way,
  output ftb_ent_t                s2_ftb_ent,
  // S2 uFTB FastFill (active only when commit upd_en == 0)
  input  logic                    ff_en,
  input  logic [XLEN_BITS-1:0]    ff_base,
  input  ftb_ent_t                ff_ent,
  // Registered T1 commit update from bpu_ftb_brq (ZERO T0 read!)
  input  logic                    upd_en,
  input  logic [XLEN_BITS-1:0]    upd_start,
  input  ex_fh_t                  upd_ex_fh,
  input  logic                    upd_ah_v,
  input  logic                    upd_ah_self0,
  input  logic [XLEN_BITS-1:0]    upd_ah_key_base,
  input  logic [XLEN_BITS-1:0]    upd_prev_base,
  input  ex_fh_t                  upd_ah_key_ex_fh,
  input  ftb1_lookup_meta_t       upd_ftb1_meta,
  input  ah_pred_meta_t           upd_ah_meta,
  input  ftb_br_upd_t             upd_br,
  // Predecode false-branch slot clear
  input  logic                    clr_en,
  input  logic [XLEN_BITS-1:0]    clr_base,
  input  logic [XLEN_BITS-1:0]    clr_pc
);

  // ---- Predict read bank mask for Main FTB1 (Predict-Always-Wins) ----
  logic [BPU_FTB1_BANKS-1:0] ftb1_rd_mask;
  always_comb begin
    ftb1_rd_mask = '0;
    if (s1_valid) ftb1_rd_mask[s2_bank_of_pc(s1_base)] = 1'b1;
  end

  // ---- Inter-module commit plan & self0/2-Ahead index reconstruction ----
  logic                  ftb1_sl_v, ftb1_sl_v_raw, ftb1_any_v;
  logic [FTB_SLOT_W-1:0] ftb1_sl_idx;
  logic [1:0]            ftb1_sl_ctr;
  ftb_ent_t              ftb1_new_ent;
  logic                  s2_slot_meta_ok, has_ah, is_s0_train;
  logic                  ah_tage_upd_en, ah_itt_upd_en;
  logic [XLEN_BITS-1:0]  ah_kbase, ah_pbase;
  ex_fh_t                ah_kfh;
  ex_tage_ix_t           upd_ah_ex_ix;
  itt_ix_t               upd_ah_itt_ix;

  assign ftb1_sl_v = upd_en && ftb1_any_v && ftb1_sl_v_raw;

  always_comb begin
    has_ah          = upd_ah_v || upd_ah_self0;
    is_s0_train     = !upd_ah_v && upd_ah_self0;
    ah_kbase        = is_s0_train ? upd_start : upd_ah_key_base;
    ah_kfh          = is_s0_train ? upd_ex_fh : upd_ah_key_ex_fh;
    ah_pbase        = is_s0_train ? '0 : upd_prev_base;
    upd_ah_ex_ix    = make_ah_ex_tage_index(ah_kbase, upd_start, ah_kfh, upd_ex_fh, ah_pbase, is_s0_train);
    upd_ah_itt_ix   = make_ah_itt_index(ah_kbase, upd_start, ah_kfh, upd_ex_fh, ah_pbase, is_s0_train);
    ah_tage_upd_en  = upd_en && has_ah && (upd_br.br_type == BR_DIRECT) && ftb1_any_v && ftb1_sl_v_raw;
    ah_itt_upd_en   = upd_en && has_ah && ftb_br_ind(upd_br.br_type) && upd_br.actual_dir;
    s2_slot_meta_ok = upd_ftb1_meta.hit &&
                      upd_ftb1_meta.ent.s[ftb1_sl_idx].valid &&
                      (upd_ftb1_meta.ent.s[ftb1_sl_idx].offset == upd_br.offset);
  end

  // ---- Write-wins not-hit 1RW bank arbitration for 2-Ahead ExBlockTage (4B) & ITT (2B) ----
  logic [EX_TN-1:0]                            ah_tage_wr_mask, ah_tage_sup;
  logic [NITT-1:0]                             ah_itt_wr_mask, ah_itt_sup;
  logic [EX_TN-1:0][BPU_AH_TAGE_BANKS-1:0]     ah_tage_busy;

  always_comb begin
    logic [NITT-1:0][BPU_ITT_BANKS-1:0] ah_itt_busy;
    ah_tage_busy = '0;
    ah_itt_busy  = '0;
    for (int k = 0; k < EX_TN; k++)
      if (ah_tage_wr_mask[k]) ah_tage_busy[k][upd_ah_ex_ix.idx[k][1:0]] = 1'b1;
    for (int k = 0; k < NITT; k++)
      if (ah_itt_wr_mask[k]) ah_itt_busy[k][upd_ah_itt_ix.idx[k][0]] = 1'b1;

    ah_tage_sup = '0;
    ah_itt_sup  = '0;
    if (ah_rd_en) begin
      for (int k = 0; k < EX_TN; k++) begin
        if (ah_tage_busy[k][ah_rd_ex_ix.idx[k][1:0]]) ah_tage_sup[k] = 1'b1;
        else                                          ah_tage_busy[k][ah_rd_ex_ix.idx[k][1:0]] = 1'b1;
      end
      for (int k = 0; k < NITT; k++) begin
        if (ah_itt_busy[k][ah_rd_itt_ix.idx[k][0]]) ah_itt_sup[k] = 1'b1;
        else                                        ah_itt_busy[k][ah_rd_itt_ix.idx[k][0]] = 1'b1;
      end
    end
  end

  // ---- 1. S0 uFTB (64x4 = 256 compact FF; Priority: commit mirror > S2 FastFill) ----
  logic                 uftb_wr_en, uftb_wr_has_taken;
  logic [XLEN_BITS-1:0] uftb_wr_base;
  ftb_ent_t             uftb_wr_ent;

  assign uftb_wr_en        = upd_en || ff_en;
  assign uftb_wr_base      = upd_en ? upd_start : ff_base;
  assign uftb_wr_ent       = upd_en ? ftb1_new_ent : ff_ent;
  assign uftb_wr_has_taken = upd_en ? upd_br.actual_dir : 1'b1;

  bpu_uftb u_ftb0 (
    .clk, .rst_n,
    .rd_base(s0_base), .rd_hit(ftb0_hit), .rd_ent(ftb0_ent),
    .wr_en(uftb_wr_en), .wr_base(uftb_wr_base), .wr_ent(uftb_wr_ent), .wr_has_taken(uftb_wr_has_taken),
    .clr_en(clr_en), .clr_base(clr_base), .clr_pc(clr_pc)
  );

  // ---- 2. Main FTB1 (1024x4 = 2-Bank 512x4w 1RW -> 24 x 512x72 macros) ----
  bpu_ftb_tab #(
    .SETS(FTB_S1_SETS), .WAYS(FTB_S1_WAYS), .NB(BPU_FTB1_BANKS), .TAG_W(FTB_S1_TAG_W), .TAG("BPU_FTB1")
  ) u_ftb1 (
    .clk, .rst_n,
    .rd_en(s1_valid), .rd_base(s1_base), .rd_cmp_base(s2_base),
    .rd_hit(s2_ftb_hit), .rd_way(s2_ftb_way), .rd_ent(s2_ftb_ent),
    .upd_en(upd_en), .upd_base(upd_start), .upd_br(upd_br),
    .upd_meta_hit(upd_ftb1_meta.hit), .upd_meta_way(upd_ftb1_meta.way), .upd_meta_ent(upd_ftb1_meta.ent),
    .rd_bank_mask(ftb1_rd_mask),
    .upd_slot_valid(ftb1_sl_v_raw), .upd_slot_idx(ftb1_sl_idx), .upd_slot_ctr(ftb1_sl_ctr),
    .upd_any_v(ftb1_any_v), .upd_new_ent_o(ftb1_new_ent),
    .clr_en(clr_en), .clr_base(clr_base), .clr_pc(clr_pc)
  );

  // ---- 3. 2-Way 6-table 2-Ahead ExBlockTage (4-Bank 512x128b 1RW -> 48 x 512x72 macros) ----
  bpu_ftb_ex_tage u_ah_ex_tage (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah_tage_sup), .rd_ix(ah_rd_ex_ix),
    .rd_raw(ah_sram_raw.ex_tage_raw), .use_alt_o(ah_use_alt),
    .upd_en(ah_tage_upd_en), .upd_ix(upd_ah_ex_ix), .upd_sl(ftb1_sl_idx),
    .upd_real_dir(upd_br.actual_dir), .upd_base_ctr(ftb1_sl_ctr),
    .upd_meta_valid(s2_slot_meta_ok), .upd_meta(upd_ah_meta.ex_tage[ftb1_sl_idx]),
    .tbl_wr_mask_o(ah_tage_wr_mask),
    .tbl_busy_mask(ah_tage_busy)
  );

  // ---- 4. 4-table 512-entry 2-Ahead ITT (2-Bank 256x52b 1RW -> 8 x 256x64 macros) ----
  bpu_ftb_itt #(.N_ENT(FTB_ITT_N), .NB(BPU_ITT_BANKS), .HOLD_RD0(1'b1), .TAG("BPU_AITT")) u_aitt (
    .clk, .rst_n,
    .rd_en(ah_rd_en), .rd_sup(ah_itt_sup), .rd_ix(ah_rd_itt_ix), .rd_raw(ah_sram_raw.itt_raw),
    .upd_en(ah_itt_upd_en), .upd_ix(upd_ah_itt_ix), .upd_target(upd_br.target), .upd_meta(upd_ah_meta.itt),
    .wr_mask_o(ah_itt_wr_mask)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_arr;
  assign unused_arr = ^{ftb1_sl_v, ah_rd_ex_ix.w};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
`default_nettype wire
