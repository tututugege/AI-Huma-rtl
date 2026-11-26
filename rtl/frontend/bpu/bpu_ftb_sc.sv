// Ref: front-end/BPU/BpuSc.h  struct StatCorrector (v10: Zero-T0-Read Meta + WRBypass + 2-Bank 1RW + FF Bias)
//   - bias_q: 64x4x4x6b FF register file (ZERO bank conflicts!)
//   - u_gehl[0..3]: 4 tables x 2 banks x (256 x 24b) 1RW (MASK_W=4)
//   - u_imli / u_loc: 2 banks x (128 x 24b) 1RW (MASK_W=4)
`default_nettype none

module bpu_ftb_sc import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                  clk,
  input  logic                  rst_n,
  // S1 dual sync read launch (per-subtable sup[6:1] enforces write-wins on 2-Bank 1RW SRAMs)
  input  logic                  rd_en,
  input  logic [6:0]            rd_sup,
  input  logic                  rd2_en,
  input  logic [6:0]            rd2_sup,
  /* verilator lint_off UNUSEDSIGNAL */
  input  sc_ix_t                rd_ix,
  input  sc_ix_t                rd2_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [7:0]            rd_loc_idx_comb_o,
  output logic [7:0]            rd2_loc_idx_comb_o,
  output sc_raw_t               rd_raw,
  output logic [7:0]            rd_loc_idx_q_o,
  output sc_raw_t               rd2_raw,
  output logic [7:0]            rd2_loc_idx_q_o,
  output logic [15:0][5:0]      thres_o,
  // Single-cycle pure commit write (computed from ftb_rec Meta + 7x 8-entry FF WRBypass; ZERO T0 read!)
  input  logic                  upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  sc_ix_t                upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTB_SLOT_W-1:0] upd_sl,
  input  logic                  upd_real_dir,
  input  logic                  upd_tage_pred,
  input  logic                  upd_prov_hit,
  input  logic [2:0]            upd_prov_cnt,
  input  logic [1:0]            upd_base_cnt,
  input  logic                  upd_meta_valid,
  input  sc_meta_t              upd_meta,
  // Combinational write info exported to bpu_ftb_arrays for 2-bank write-wins arbitration
  output logic                  wr_en_o,
  output logic [7:0]            wr_loc_idx_o
);

  function automatic logic [5:0] sat_upd6(input logic signed [5:0] v, input logic taken);
    logic signed [6:0] nv;
    nv = $signed({v[5], v}) + (taken ? 7'sd1 : -7'sd1);
    if (nv > 7'sd31)       return 6'sd31;
    else if (nv < -7'sd32) return -6'sd32;
    else                   return nv[5:0];
  endfunction

  // ---- Small FF arrays: Bias (64x4x4x6b), LHT (64x10b), per-PC threshold (16x6b) ----
  logic signed [5:0] bias_q  [SC_BIAS_SETS][FTB_SLOTS][4];
  logic [9:0]        lht_q   [SC_LHT_N];
  logic [15:0][5:0]  thres_q, thres_d;
  logic [7:0]        li0, li2, li_upd_fallback, upd_li;
  logic [7:0]        rd_loc_idx_q, rd2_loc_idx_q;
  logic [6:0]        rd0_sup_q, rd1_sup_q;
  logic signed [3:0][5:0] bias_rd0_q [FTB_SLOTS];
  logic signed [3:0][5:0] bias_rd1_q [FTB_SLOTS];

  assign thres_o            = thres_q;
  assign rd_loc_idx_comb_o  = li0;
  assign rd2_loc_idx_comb_o = li2;
  assign rd_loc_idx_q_o     = rd_loc_idx_q;
  assign rd2_loc_idx_q_o    = rd2_loc_idx_q;

  always_comb begin
    logic [9:0] lh0, lh2, lhu;
    lh0             = lht_q[rd_ix.lht_idx];
    lh2             = lht_q[rd2_ix.lht_idx];
    lhu             = lht_q[upd_ix.lht_idx];
    li0             = 8'(rd_ix.w  ^ {22'b0, lh0} ^ {28'b0, lh0[9:6]});
    li2             = 8'(rd2_ix.w ^ {22'b0, lh2} ^ {28'b0, lh2[9:6]});
    li_upd_fallback = 8'(upd_ix.w ^ {22'b0, lhu} ^ {28'b0, lhu[9:6]});
    upd_li          = upd_meta_valid ? upd_meta.loc_idx : li_upd_fallback;
  end

  // ---- 7 x 8-entry FF WRBypass instances (matching ScSubWrBypass wrb[7]) ----
  logic        upd_low_conf, sc_do_wr;
  logic [1:0]  upd_bway;
  logic [10:0] wrb_key_g [SC_GEHL_N];
  logic [9:0]  wrb_key_b, wrb_key_i, wrb_key_l;
  logic        wrb_hit_b, wrb_hit_i, wrb_hit_l;
  logic        wrb_hit_g [SC_GEHL_N];
  logic [5:0]  wrb_val_b, wrb_val_i, wrb_val_l;
  logic [5:0]  wrb_val_g [SC_GEHL_N];
  logic [5:0]  bias_new, imli_new, loc_new;
  logic [5:0]  gehl_new  [SC_GEHL_N];

  assign upd_low_conf = upd_prov_hit ? ((upd_prov_cnt == 3'd3) || (upd_prov_cnt == 3'd4))
                                     : ((upd_base_cnt == 2'd1) || (upd_base_cnt == 2'd2));
  assign upd_bway     = {upd_tage_pred, upd_low_conf};
  assign wrb_key_b    = {upd_ix.bias_set, upd_sl, upd_bway};
  assign wrb_key_i    = {upd_ix.imli_idx, upd_sl};
  assign wrb_key_l    = {upd_li, upd_sl};

  bpu_wrbypass #(.N(BPU_WRB_N), .KEY_W(10), .DATA_W(6)) u_wrb_bias (
    .clk, .rst_n, .rd_key(wrb_key_b), .rd_hit(wrb_hit_b), .rd_data(wrb_val_b),
    .wr_en(sc_do_wr), .wr_key(wrb_key_b), .wr_data(bias_new)
  );
  for (genvar g = 0; g < SC_GEHL_N; g++) begin : g_wrb_g
    assign wrb_key_g[g] = {upd_ix.gehl_idx[g], upd_sl};
    bpu_wrbypass #(.N(BPU_WRB_N), .KEY_W(11), .DATA_W(6)) u_wrb_gehl (
      .clk, .rst_n, .rd_key(wrb_key_g[g]), .rd_hit(wrb_hit_g[g]), .rd_data(wrb_val_g[g]),
      .wr_en(sc_do_wr), .wr_key(wrb_key_g[g]), .wr_data(gehl_new[g])
    );
  end
  bpu_wrbypass #(.N(BPU_WRB_N), .KEY_W(10), .DATA_W(6)) u_wrb_imli (
    .clk, .rst_n, .rd_key(wrb_key_i), .rd_hit(wrb_hit_i), .rd_data(wrb_val_i),
    .wr_en(sc_do_wr), .wr_key(wrb_key_i), .wr_data(imli_new)
  );
  bpu_wrbypass #(.N(BPU_WRB_N), .KEY_W(10), .DATA_W(6)) u_wrb_loc (
    .clk, .rst_n, .rd_key(wrb_key_l), .rd_hit(wrb_hit_l), .rd_data(wrb_val_l),
    .wr_en(sc_do_wr), .wr_key(wrb_key_l), .wr_data(loc_new)
  );

  // ---- Pure-combinational commit plan from Meta + WRBypass ----
  sc_slot_raw_t       upd_raw;
  logic signed [10:0] upd_lsum, upd_abs, upd_th;
  logic               upd_sc_pred;
  logic [3:0]         th_idx;
  logic [5:0]         th_cur;

  always_comb begin
    upd_raw = '0;
    if (upd_meta_valid) begin
      upd_raw.bias = upd_meta.s[upd_sl].bias;
      upd_raw.gehl = upd_meta.s[upd_sl].gehl;
      upd_raw.imli = upd_meta.s[upd_sl].imli;
      upd_raw.loc  = upd_meta.s[upd_sl].loc;
    end
    if (wrb_hit_b) upd_raw.bias[upd_bway] = $signed(wrb_val_b);
    for (int g = 0; g < SC_GEHL_N; g++)
      if (wrb_hit_g[g]) upd_raw.gehl[g] = $signed(wrb_val_g[g]);
    if (wrb_hit_i) upd_raw.imli = $signed(wrb_val_i);
    if (wrb_hit_l) upd_raw.loc  = $signed(wrb_val_l);

    upd_lsum    = sc_eval_raw(upd_raw, upd_tage_pred, upd_prov_hit, upd_prov_cnt, upd_base_cnt);
    upd_abs     = (upd_lsum < 11'sd0) ? -upd_lsum : upd_lsum;
    upd_sc_pred = (upd_lsum >= 11'sd0);
    th_idx      = upd_ix.w[5:2];
    th_cur      = thres_q[th_idx];
    upd_th      = $signed({5'b0, th_cur});
    sc_do_wr    = upd_en && ((upd_sc_pred != upd_real_dir) || (upd_abs < (upd_th + 11'sd18)));

    wr_en_o      = sc_do_wr;
    wr_loc_idx_o = upd_li;

    thres_d = thres_q;
    if (upd_en && (upd_sc_pred != upd_tage_pred) &&
        (upd_abs >= (upd_th - 11'sd4)) && (upd_abs <= (upd_th + 11'sd4))) begin
      if (upd_sc_pred == upd_real_dir) begin
        if (th_cur > 6'd5)  thres_d[th_idx] = th_cur - 6'd1;
      end else begin
        if (th_cur < 6'd63) thres_d[th_idx] = th_cur + 6'd1;
      end
    end

    bias_new = sat_upd6(upd_raw.bias[upd_bway], upd_real_dir);
    for (int g = 0; g < SC_GEHL_N; g++)
      gehl_new[g] = sat_upd6(upd_raw.gehl[g], upd_real_dir);
    imli_new = sat_upd6(upd_raw.imli, upd_real_dir);
    loc_new  = sat_upd6(upd_raw.loc,  upd_real_dir);
  end

  // ---- Packed 2-Bank 1RW SRAMs (ZERO T0 read ports!) ----
  logic [23:0] gehl_rd0  [SC_GEHL_N];
  logic [23:0] gehl_rd1  [SC_GEHL_N];
  logic [23:0] imli_rd0, imli_rd1, loc_rd0, loc_rd1;
  logic [3:0]  sl_wmask;

  assign sl_wmask = 4'd1 << upd_sl;

  for (genvar g = 0; g < SC_GEHL_N; g++) begin : g_gehl
    bpu_sram_1rw_banked #(
      .W      (24),
      .DEPTH  (SC_GEHL_N_ENT),
      .NB     (BPU_SC_BANKS),
      .MASK_W (4),
      .HAS_RD1(1'b1),
      .TAG    ("BPU_SC_GEHL")
    ) u_gehl (
      .clk         (clk),
      .rd0_en      (rd_en && !rd_sup[1 + g]),
      .rd0_addr    (rd_ix.gehl_idx[g]),
      .rd0_data    (gehl_rd0[g]),
      .rd1_en      (rd2_en && !rd2_sup[1 + g]),
      .rd1_addr    (rd2_ix.gehl_idx[g]),
      .rd1_data    (gehl_rd1[g]),
      .clr_rd_en   (1'b0),
      .clr_rd_addr ('0),
      /* verilator lint_off PINCONNECTEMPTY */
      .clr_rd_data (),
      /* verilator lint_on PINCONNECTEMPTY */
      .wr_en       (sc_do_wr),
      .wr_addr     (upd_ix.gehl_idx[g]),
      .wr_data     ({4{gehl_new[g]}}),
      .wr_wmask    (sl_wmask),
      .rst_wr_en   (1'b0),
      .rst_wr_addr ('0),
      .rst_wr_data ('0),
      .rst_wr_wmask('0)
    );
  end

  bpu_sram_1rw_banked #(
    .W      (24),
    .DEPTH  (SC_IMLI_N),
    .NB     (BPU_SC_BANKS),
    .MASK_W (4),
    .HAS_RD1(1'b1),
    .TAG    ("BPU_SC_IMLI")
  ) u_imli (
    .clk         (clk),
    .rd0_en      (rd_en && !rd_sup[5]),
    .rd0_addr    (rd_ix.imli_idx),
    .rd0_data    (imli_rd0),
    .rd1_en      (rd2_en && !rd2_sup[5]),
    .rd1_addr    (rd2_ix.imli_idx),
    .rd1_data    (imli_rd1),
    .clr_rd_en   (1'b0),
    .clr_rd_addr ('0),
    /* verilator lint_off PINCONNECTEMPTY */
    .clr_rd_data (),
    /* verilator lint_on PINCONNECTEMPTY */
    .wr_en       (sc_do_wr),
    .wr_addr     (upd_ix.imli_idx),
    .wr_data     ({4{imli_new}}),
    .wr_wmask    (sl_wmask),
    .rst_wr_en   (1'b0),
    .rst_wr_addr ('0),
    .rst_wr_data ('0),
    .rst_wr_wmask('0)
  );

  bpu_sram_1rw_banked #(
    .W      (24),
    .DEPTH  (SC_LOC_N),
    .NB     (BPU_SC_BANKS),
    .MASK_W (4),
    .HAS_RD1(1'b1),
    .TAG    ("BPU_SC_LOC")
  ) u_loc (
    .clk         (clk),
    .rd0_en      (rd_en && !rd_sup[6]),
    .rd0_addr    (li0),
    .rd0_data    (loc_rd0),
    .rd1_en      (rd2_en && !rd2_sup[6]),
    .rd1_addr    (li2),
    .rd1_data    (loc_rd1),
    .clr_rd_en   (1'b0),
    .clr_rd_addr ('0),
    /* verilator lint_off PINCONNECTEMPTY */
    .clr_rd_data (),
    /* verilator lint_on PINCONNECTEMPTY */
    .wr_en       (sc_do_wr),
    .wr_addr     (upd_li),
    .wr_data     ({4{loc_new}}),
    .wr_wmask    (sl_wmask),
    .rst_wr_en   (1'b0),
    .rst_wr_addr ('0),
    .rst_wr_data ('0),
    .rst_wr_wmask('0)
  );

  // ---- Unpack predict raw (suppressed 1RW banks force 0 so unread SRAM data never leaks into Meta!) ----
  always_comb begin
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      rd_raw[sl].sup_mask  = rd0_sup_q;
      rd2_raw[sl].sup_mask = rd1_sup_q;
      rd_raw[sl].bias      = bias_rd0_q[sl];
      rd2_raw[sl].bias     = bias_rd1_q[sl];
      for (int g = 0; g < SC_GEHL_N; g++) begin
        rd_raw[sl].gehl[g]  = rd0_sup_q[1 + g] ? 6'sd0 : $signed(gehl_rd0[g][sl * 6 +: 6]);
        rd2_raw[sl].gehl[g] = rd1_sup_q[1 + g] ? 6'sd0 : $signed(gehl_rd1[g][sl * 6 +: 6]);
      end
      rd_raw[sl].imli  = rd0_sup_q[5] ? 6'sd0 : $signed(imli_rd0[sl * 6 +: 6]);
      rd2_raw[sl].imli = rd1_sup_q[5] ? 6'sd0 : $signed(imli_rd1[sl * 6 +: 6]);
      rd_raw[sl].loc   = rd0_sup_q[6] ? 6'sd0 : $signed(loc_rd0[sl * 6 +: 6]);
      rd2_raw[sl].loc  = rd1_sup_q[6] ? 6'sd0 : $signed(loc_rd1[sl * 6 +: 6]);
    end
  end

  // ---- Synchronous FF updates (Bias, LHT, threshold, pipeline regs) ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 16; i++) thres_q[i] <= 6'd35;
      for (int i = 0; i < SC_LHT_N; i++) lht_q[i] <= 10'd0;
      for (int s = 0; s < SC_BIAS_SETS; s++)
        for (int sl = 0; sl < FTB_SLOTS; sl++)
          for (int w = 0; w < 4; w++)
            bias_q[s][sl][w] <= 6'sd0;
      rd0_sup_q     <= '0;
      rd1_sup_q     <= '0;
      rd_loc_idx_q  <= '0;
      rd2_loc_idx_q <= '0;
      for (int sl = 0; sl < FTB_SLOTS; sl++) begin
        bias_rd0_q[sl] <= '0;
        bias_rd1_q[sl] <= '0;
      end
    end else begin
      thres_q <= thres_d;
      if (rd_en) begin
        rd0_sup_q    <= rd_sup;
        rd_loc_idx_q <= li0;
        for (int sl = 0; sl < FTB_SLOTS; sl++)
          for (int w = 0; w < 4; w++)
            bias_rd0_q[sl][w] <= bias_q[rd_ix.bias_set][sl][w];
      end
      if (rd2_en) begin
        rd1_sup_q     <= rd2_sup;
        rd2_loc_idx_q <= li2;
        for (int sl = 0; sl < FTB_SLOTS; sl++)
          for (int w = 0; w < 4; w++)
            bias_rd1_q[sl][w] <= bias_q[rd2_ix.bias_set][sl][w];
      end
      if (upd_en) begin
        lht_q[upd_ix.lht_idx] <= {lht_q[upd_ix.lht_idx][8:0], upd_real_dir};
      end
      if (sc_do_wr) begin
        bias_q[upd_ix.bias_set][upd_sl][upd_bway] <= $signed(bias_new);
      end
    end
  end

endmodule

`default_nettype wire
