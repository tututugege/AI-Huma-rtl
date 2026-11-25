// Ref: front-end/BPU/BpuSc.h  struct StatCorrector (S2 Statistical Corrector: Bias + 4 GEHL + IMLI + Local + LHT)
`default_nettype none

module bpu_ftb_sc import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                  clk,
  input  logic                  rst_n,
  // S1 dual read ports (Block A & Block B, all 4 slots)
  /* verilator lint_off UNUSEDSIGNAL */
  input  sc_ix_t                rd_ix,
  input  sc_ix_t                rd2_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output sc_raw_t               rd_raw,
  output sc_raw_t               rd2_raw,
  output logic [15:0][5:0]      thres_o,
  // Single-slot commit update port (uses live TAGE pred from u_s2_tage)
  input  logic                  upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  sc_ix_t                upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTB_SLOT_W-1:0] upd_sl,
  input  logic                  upd_real_dir,
  input  logic                  upd_tage_pred,
  input  logic                  upd_prov_hit,
  input  logic [2:0]            upd_prov_cnt,
  input  logic [1:0]            upd_base_cnt
);

  localparam int N_RD = 3;

  function automatic logic [5:0] sat_upd6(input logic signed [5:0] v, input logic taken);
    logic signed [6:0] nv;
    nv = $signed({v[5], v}) + (taken ? 7'sd1 : -7'sd1);
    if (nv > 7'sd31)       return 6'sd31;
    else if (nv < -7'sd32) return -6'sd32;
    else                   return nv[5:0];
  endfunction

  // ---- Small register arrays: LHT (64x10b) & per-PC threshold (16x6b) ----
  logic [9:0]       lht_q [SC_LHT_N];
  logic [15:0][5:0] thres_q, thres_d;

  assign thres_o = thres_q;

  // ---- Backing memories (6-bit signed weights) ----
  logic [5:0] bias_rd_a [FTB_SLOTS][4][N_RD];
  logic [5:0] bias_rd_d [FTB_SLOTS][4][N_RD];
  logic       bias_wr_e [FTB_SLOTS][4][1];
  logic [5:0] bias_wr_a [FTB_SLOTS][4][1];
  logic [5:0] bias_wr_d [FTB_SLOTS][4][1];

  logic [8:0] gehl_rd_a [SC_GEHL_N][FTB_SLOTS][N_RD];
  logic [5:0] gehl_rd_d [SC_GEHL_N][FTB_SLOTS][N_RD];
  logic       gehl_wr_e [SC_GEHL_N][FTB_SLOTS][1];
  logic [8:0] gehl_wr_a [SC_GEHL_N][FTB_SLOTS][1];
  logic [5:0] gehl_wr_d [SC_GEHL_N][FTB_SLOTS][1];

  logic [7:0] imli_rd_a [FTB_SLOTS][N_RD];
  logic [5:0] imli_rd_d [FTB_SLOTS][N_RD];
  logic       imli_wr_e [FTB_SLOTS][1];
  logic [7:0] imli_wr_a [FTB_SLOTS][1];
  logic [5:0] imli_wr_d [FTB_SLOTS][1];

  logic [7:0] loc_rd_a  [FTB_SLOTS][N_RD];
  logic [5:0] loc_rd_d  [FTB_SLOTS][N_RD];
  logic       loc_wr_e  [FTB_SLOTS][1];
  logic [7:0] loc_wr_a  [FTB_SLOTS][1];
  logic [5:0] loc_wr_d  [FTB_SLOTS][1];

  for (genvar sl = 0; sl < FTB_SLOTS; sl++) begin : g_sl
    for (genvar w = 0; w < 4; w++) begin : g_bias
      bpu_mem #(.W(6), .DEPTH(SC_BIAS_SETS), .N_RD(N_RD), .N_WR(1)) u_bias (
        .clk, .rst_n,
        .rd_addr(bias_rd_a[sl][w]), .rd_data(bias_rd_d[sl][w]),
        .wr_en(bias_wr_e[sl][w]), .wr_addr(bias_wr_a[sl][w]), .wr_data(bias_wr_d[sl][w])
      );
    end
    for (genvar g = 0; g < SC_GEHL_N; g++) begin : g_gehl
      bpu_mem #(.W(6), .DEPTH(SC_GEHL_N_ENT), .N_RD(N_RD), .N_WR(1)) u_gehl (
        .clk, .rst_n,
        .rd_addr(gehl_rd_a[g][sl]), .rd_data(gehl_rd_d[g][sl]),
        .wr_en(gehl_wr_e[g][sl]), .wr_addr(gehl_wr_a[g][sl]), .wr_data(gehl_wr_d[g][sl])
      );
    end
    bpu_mem #(.W(6), .DEPTH(SC_IMLI_N), .N_RD(N_RD), .N_WR(1)) u_imli (
      .clk, .rst_n,
      .rd_addr(imli_rd_a[sl]), .rd_data(imli_rd_d[sl]),
      .wr_en(imli_wr_e[sl]), .wr_addr(imli_wr_a[sl]), .wr_data(imli_wr_d[sl])
    );
    bpu_mem #(.W(6), .DEPTH(SC_LOC_N), .N_RD(N_RD), .N_WR(1)) u_loc (
      .clk, .rst_n,
      .rd_addr(loc_rd_a[sl]), .rd_data(loc_rd_d[sl]),
      .wr_en(loc_wr_e[sl]), .wr_addr(loc_wr_a[sl]), .wr_data(loc_wr_d[sl])
    );
  end

  // ---- LHT lookup & read port wiring ----
  logic [9:0]   lh0, lh1, lh2;
  logic [7:0]   li0, li1, li2;
  sc_slot_raw_t upd_raw;

  always_comb begin
    lh0 = lht_q[rd_ix.lht_idx];
    lh1 = lht_q[upd_ix.lht_idx];
    lh2 = lht_q[rd2_ix.lht_idx];
    li0 = 8'(rd_ix.w  ^ {22'b0, lh0} ^ {28'b0, lh0[9:6]});
    li1 = 8'(upd_ix.w ^ {22'b0, lh1} ^ {28'b0, lh1[9:6]});
    li2 = 8'(rd2_ix.w ^ {22'b0, lh2} ^ {28'b0, lh2[9:6]});

    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      for (int w = 0; w < 4; w++) begin
        bias_rd_a[sl][w][0] = rd_ix.bias_set;
        bias_rd_a[sl][w][1] = upd_ix.bias_set;
        bias_rd_a[sl][w][2] = rd2_ix.bias_set;
        rd_raw[sl].bias[w]  = $signed(bias_rd_d[sl][w][0]);
        rd2_raw[sl].bias[w] = $signed(bias_rd_d[sl][w][2]);
      end
      for (int g = 0; g < SC_GEHL_N; g++) begin
        gehl_rd_a[g][sl][0] = rd_ix.gehl_idx[g];
        gehl_rd_a[g][sl][1] = upd_ix.gehl_idx[g];
        gehl_rd_a[g][sl][2] = rd2_ix.gehl_idx[g];
        rd_raw[sl].gehl[g]  = $signed(gehl_rd_d[g][sl][0]);
        rd2_raw[sl].gehl[g] = $signed(gehl_rd_d[g][sl][2]);
      end
      imli_rd_a[sl][0] = rd_ix.imli_idx;
      imli_rd_a[sl][1] = upd_ix.imli_idx;
      imli_rd_a[sl][2] = rd2_ix.imli_idx;
      rd_raw[sl].imli  = $signed(imli_rd_d[sl][0]);
      rd2_raw[sl].imli = $signed(imli_rd_d[sl][2]);

      loc_rd_a[sl][0] = li0;
      loc_rd_a[sl][1] = li1;
      loc_rd_a[sl][2] = li2;
      rd_raw[sl].loc  = $signed(loc_rd_d[sl][0]);
      rd2_raw[sl].loc = $signed(loc_rd_d[sl][2]);
    end

    for (int w = 0; w < 4; w++) upd_raw.bias[w] = $signed(bias_rd_d[upd_sl][w][1]);
    for (int g = 0; g < SC_GEHL_N; g++) upd_raw.gehl[g] = $signed(gehl_rd_d[g][upd_sl][1]);
    upd_raw.imli = $signed(imli_rd_d[upd_sl][1]);
    upd_raw.loc  = $signed(loc_rd_d[upd_sl][1]);
  end

  // ---- Commit update logic ----
  logic signed [10:0] upd_lsum, upd_abs_sum, upd_th_s;
  logic               upd_sc_pred, upd_low_conf, do_tbl_upd;
  logic [1:0]         upd_bway;
  logic [3:0]         th_idx;
  logic [5:0]         th_cur;

  always_comb begin
    upd_lsum     = sc_eval_raw(upd_raw, upd_tage_pred, upd_prov_hit, upd_prov_cnt, upd_base_cnt);
    upd_abs_sum  = (upd_lsum < 11'sd0) ? -upd_lsum : upd_lsum;
    upd_sc_pred  = (upd_lsum >= 11'sd0);
    th_idx       = upd_ix.w[5:2];
    th_cur       = thres_q[th_idx];
    upd_th_s     = $signed({5'b0, th_cur});

    thres_d = thres_q;
    if (upd_en && (upd_sc_pred != upd_tage_pred) &&
        (upd_abs_sum >= (upd_th_s - 11'sd4)) && (upd_abs_sum <= (upd_th_s + 11'sd4))) begin
      if (upd_sc_pred == upd_real_dir) begin
        if (th_cur > 6'd5)  thres_d[th_idx] = th_cur - 6'd1;
      end else begin
        if (th_cur < 6'd63) thres_d[th_idx] = th_cur + 6'd1;
      end
    end

    upd_low_conf = upd_prov_hit ? ((upd_prov_cnt == 3'd3) || (upd_prov_cnt == 3'd4))
                                : ((upd_base_cnt == 2'd1) || (upd_base_cnt == 2'd2));
    upd_bway     = {upd_tage_pred, upd_low_conf};
    do_tbl_upd   = upd_en && ((upd_sc_pred != upd_real_dir) || (upd_abs_sum < (upd_th_s + 11'sd18)));

    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      for (int w = 0; w < 4; w++) begin
        bias_wr_e[sl][w][0] = do_tbl_upd && (FTB_SLOT_W'(sl) == upd_sl) && (2'(w) == upd_bway);
        bias_wr_a[sl][w][0] = upd_ix.bias_set;
        bias_wr_d[sl][w][0] = sat_upd6(upd_raw.bias[w], upd_real_dir);
      end
      for (int g = 0; g < SC_GEHL_N; g++) begin
        gehl_wr_e[g][sl][0] = do_tbl_upd && (FTB_SLOT_W'(sl) == upd_sl);
        gehl_wr_a[g][sl][0] = upd_ix.gehl_idx[g];
        gehl_wr_d[g][sl][0] = sat_upd6(upd_raw.gehl[g], upd_real_dir);
      end
      imli_wr_e[sl][0] = do_tbl_upd && (FTB_SLOT_W'(sl) == upd_sl);
      imli_wr_a[sl][0] = upd_ix.imli_idx;
      imli_wr_d[sl][0] = sat_upd6(upd_raw.imli, upd_real_dir);

      loc_wr_e[sl][0] = do_tbl_upd && (FTB_SLOT_W'(sl) == upd_sl);
      loc_wr_a[sl][0] = li1;
      loc_wr_d[sl][0] = sat_upd6(upd_raw.loc, upd_real_dir);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < SC_LHT_N; i++) lht_q[i] <= 10'd0;
      for (int i = 0; i < 16; i++)       thres_q[i] <= 6'd35;
    end else begin
      if (upd_en) lht_q[upd_ix.lht_idx] <= {lh1[8:0], upd_real_dir};
      thres_q <= thres_d;
    end
  end

endmodule

`default_nettype wire
