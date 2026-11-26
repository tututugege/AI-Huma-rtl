// Ref: front-end/BPU/BpuFtb.h  struct BlockTage (4-slot block-indexed TAGE array, strict sync 1R1W SRAM)
`default_nettype none

module bpu_ftb_tage import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    N_ENT         = 1024,
  parameter bit    HAS_BASE      = 1'b0,
  parameter bit    USE_LIVE_PRED = 1'b1,
  parameter bit    HAS_RD2       = 1'b0,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG          = "BPU_ATAGE"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                  clk,
  input  logic                  rst_n,
  // Predict sync read launch (1-cycle latency; WF=0 READ_FIRST)
  input  logic                  rd_en,
  input  logic                  rd2_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t               rd_ix,
  input  ftb_ix_t               rd2_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ftb_tage_raw_t         rd_raw,
  output ftb_tage_raw_t         rd2_raw,
  output logic                  prefer_alt,
  // T0 sync read launch for commit update (WF=1 WRITE_FIRST)
  input  logic                  t0_upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t               t0_upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  // T1 single-slot commit update execute & write
  input  logic                  t1_upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t               t1_upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTB_SLOT_W-1:0] t1_upd_sl,
  input  logic                  t1_upd_real_dir,
  input  logic                  t1_upd_pred_dir,
  input  logic                  t1_upd_alt_pred,
  input  logic [PCPN_W-1:0]     t1_upd_pcpn,
  input  logic [1:0]            t1_upd_base_ctr
);

  localparam int IDX_W = $clog2(N_ENT);
  localparam int N_RD  = HAS_RD2 ? 3 : 2;
  localparam logic [N_RD-1:0] WF_MASK = N_RD'(3'b010);

  typedef struct packed {
    logic [FTB_TAG_W-1:0] tag;
    logic [2:0]           cnt;
  } tc_t;

  // ---- Control state registers ----
  logic [3:0]  lsfr_q, lsfr_d;
  logic [31:0] reset_cnt_q, reset_cnt_d;
  logic [3:0]  use_alt_q, use_alt_d;

  assign prefer_alt = (use_alt_q <= FTB_USE_ALT_THR);

  // ---- Backing strict sync 1R1W SRAMs ----
  /* verilator lint_off UNUSEDSIGNAL */
  logic             base_rd_e  [FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] base_rd_a  [FTB_SLOTS][N_RD];
  logic [1:0]       base_rd_d  [FTB_SLOTS][N_RD];
  logic             base_wr_e  [FTB_SLOTS];
  logic [IDX_W-1:0] base_wr_a  [FTB_SLOTS];
  logic [1:0]       base_wr_d  [FTB_SLOTS];
  /* verilator lint_on UNUSEDSIGNAL */

  logic             tc_rd_e    [TN][FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] tc_rd_a    [TN][FTB_SLOTS][N_RD];
  tc_t              tc_rd_d    [TN][FTB_SLOTS][N_RD];
  logic             tc_wr_e    [TN][FTB_SLOTS];
  logic [IDX_W-1:0] tc_wr_a    [TN][FTB_SLOTS];
  tc_t              tc_wr_d    [TN][FTB_SLOTS];

  logic             ulo_rd_e   [TN][FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] ulo_rd_a   [TN][FTB_SLOTS][N_RD];
  logic [0:0]       ulo_rd_d   [TN][FTB_SLOTS][N_RD];
  logic             ulo_wr_e   [TN][FTB_SLOTS];
  logic [IDX_W-1:0] ulo_wr_a   [TN][FTB_SLOTS];
  logic [0:0]       ulo_wr_d   [TN][FTB_SLOTS];

  logic             uhi_rd_e   [TN][FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] uhi_rd_a   [TN][FTB_SLOTS][N_RD];
  logic [0:0]       uhi_rd_d   [TN][FTB_SLOTS][N_RD];
  logic             uhi_wr_e   [TN][FTB_SLOTS];
  logic [IDX_W-1:0] uhi_wr_a   [TN][FTB_SLOTS];
  logic [0:0]       uhi_wr_d   [TN][FTB_SLOTS];

  for (genvar sl = 0; sl < FTB_SLOTS; sl++) begin : g_sl
    if (HAS_BASE) begin : g_base
      bpu_sram_sync #(.W(2), .DEPTH(N_ENT), .N_RD(N_RD), .WF_MASK(WF_MASK), .TAG(TAG)) u_base (
        .clk, .rd_en(base_rd_e[sl]), .rd_addr(base_rd_a[sl]), .rd_data(base_rd_d[sl]),
        .wr_en(base_wr_e[sl]), .wr_addr(base_wr_a[sl]), .wr_data(base_wr_d[sl])
      );
    end else begin : g_nobase
      for (genvar p = 0; p < N_RD; p++) begin : g_nb
        assign base_rd_d[sl][p] = 2'd0;
      end
    end

    for (genvar t = 0; t < TN; t++) begin : g_tbl
      bpu_sram_sync #(.W($bits(tc_t)), .DEPTH(N_ENT), .N_RD(N_RD), .T(tc_t), .WF_MASK(WF_MASK), .TAG(TAG)) u_tc (
        .clk, .rd_en(tc_rd_e[t][sl]), .rd_addr(tc_rd_a[t][sl]), .rd_data(tc_rd_d[t][sl]),
        .wr_en(tc_wr_e[t][sl]), .wr_addr(tc_wr_a[t][sl]), .wr_data(tc_wr_d[t][sl])
      );
      bpu_sram_sync #(.W(1), .DEPTH(N_ENT), .N_RD(N_RD), .WF_MASK(WF_MASK), .TAG(TAG)) u_ulo (
        .clk, .rd_en(ulo_rd_e[t][sl]), .rd_addr(ulo_rd_a[t][sl]), .rd_data(ulo_rd_d[t][sl]),
        .wr_en(ulo_wr_e[t][sl]), .wr_addr(ulo_wr_a[t][sl]), .wr_data(ulo_wr_d[t][sl])
      );
      bpu_sram_sync #(.W(1), .DEPTH(N_ENT), .N_RD(N_RD), .WF_MASK(WF_MASK), .TAG(TAG)) u_uhi (
        .clk, .rd_en(uhi_rd_e[t][sl]), .rd_addr(uhi_rd_a[t][sl]), .rd_data(uhi_rd_d[t][sl]),
        .wr_en(uhi_wr_e[t][sl]), .wr_addr(uhi_wr_a[t][sl]), .wr_data(uhi_wr_d[t][sl])
      );
    end
  end

  // ---- Read ports & predict raw assembly ----
  ftb_tage_slot_raw_t upd_raw;

  always_comb begin
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      base_rd_e[sl][0]    = rd_en;
      base_rd_e[sl][1]    = t0_upd_en;
      base_rd_a[sl][0]    = rd_ix.base_idx[IDX_W-1:0];
      base_rd_a[sl][1]    = t0_upd_ix.base_idx[IDX_W-1:0];
      rd_raw[sl].base_cnt = base_rd_d[sl][0];
      for (int t = 0; t < TN; t++) begin
        tc_rd_e[t][sl][0]    = rd_en;
        tc_rd_e[t][sl][1]    = t0_upd_en;
        tc_rd_a[t][sl][0]    = rd_ix.idx[t][IDX_W-1:0];
        tc_rd_a[t][sl][1]    = t0_upd_ix.idx[t][IDX_W-1:0];
        ulo_rd_e[t][sl][0]   = rd_en;
        ulo_rd_e[t][sl][1]   = t0_upd_en;
        ulo_rd_a[t][sl][0]   = rd_ix.idx[t][IDX_W-1:0];
        ulo_rd_a[t][sl][1]   = t0_upd_ix.idx[t][IDX_W-1:0];
        uhi_rd_e[t][sl][0]   = rd_en;
        uhi_rd_e[t][sl][1]   = t0_upd_en;
        uhi_rd_a[t][sl][0]   = rd_ix.idx[t][IDX_W-1:0];
        uhi_rd_a[t][sl][1]   = t0_upd_ix.idx[t][IDX_W-1:0];
        rd_raw[sl].tag[t]    = tc_rd_d[t][sl][0].tag;
        rd_raw[sl].cnt[t]    = tc_rd_d[t][sl][0].cnt;
        rd_raw[sl].useful[t] = {uhi_rd_d[t][sl][0], ulo_rd_d[t][sl][0]};
      end
    end

    upd_raw.base_cnt = base_rd_d[t1_upd_sl][1];
    for (int t = 0; t < TN; t++) begin
      upd_raw.tag[t]    = tc_rd_d[t][t1_upd_sl][1].tag;
      upd_raw.cnt[t]    = tc_rd_d[t][t1_upd_sl][1].cnt;
      upd_raw.useful[t] = {uhi_rd_d[t][t1_upd_sl][1], ulo_rd_d[t][t1_upd_sl][1]};
    end
  end

  if (HAS_RD2) begin : g_rd2
    always_comb begin
      for (int sl = 0; sl < FTB_SLOTS; sl++) begin
        base_rd_e[sl][2]     = rd2_en;
        base_rd_a[sl][2]     = rd2_ix.base_idx[IDX_W-1:0];
        rd2_raw[sl].base_cnt = base_rd_d[sl][2];
        for (int t = 0; t < TN; t++) begin
          tc_rd_e[t][sl][2]     = rd2_en;
          tc_rd_a[t][sl][2]     = rd2_ix.idx[t][IDX_W-1:0];
          ulo_rd_e[t][sl][2]    = rd2_en;
          ulo_rd_a[t][sl][2]    = rd2_ix.idx[t][IDX_W-1:0];
          uhi_rd_e[t][sl][2]    = rd2_en;
          uhi_rd_a[t][sl][2]    = rd2_ix.idx[t][IDX_W-1:0];
          rd2_raw[sl].tag[t]    = tc_rd_d[t][sl][2].tag;
          rd2_raw[sl].cnt[t]    = tc_rd_d[t][sl][2].cnt;
          rd2_raw[sl].useful[t] = {uhi_rd_d[t][sl][2], ulo_rd_d[t][sl][2]};
        end
      end
    end
  end else begin : g_nord2
    assign rd2_raw = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_rd2;
    assign unused_rd2 = rd2_en;
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ---- T1 Effective prediction metadata & allocation target ----
  ftb_tage_pred_t    live_p;
  logic              eff_pred, eff_alt, pdir, is_weak;
  logic [PCPN_W-1:0] eff_pcpn, start_t;
  logic [2:0]        prov_cnt, prov_cnt_new;
  logic [1:0]        prov_u, prov_u_new, base_cnt_new;
  logic [2:0]        nf;
  logic [1:0]        free0, free1, chosen_t;
  logic              do_alloc, do_dec_u;

  always_comb begin
    live_p   = ftb_tage_select(t1_upd_ix, upd_raw, !HAS_BASE, t1_upd_base_ctr, prefer_alt);
    eff_pred = USE_LIVE_PRED ? live_p.pred : t1_upd_pred_dir;
    eff_alt  = USE_LIVE_PRED ? live_p.alt  : t1_upd_alt_pred;
    eff_pcpn = USE_LIVE_PRED ? live_p.pcpn : t1_upd_pcpn;

    prov_cnt     = (eff_pcpn < PCPN_W'(TN)) ? upd_raw.cnt[eff_pcpn[1:0]]    : 3'd0;
    prov_u       = (eff_pcpn < PCPN_W'(TN)) ? upd_raw.useful[eff_pcpn[1:0]] : 2'd0;
    pdir         = (prov_cnt >= 3'd4);
    is_weak      = (prov_cnt == 3'd3);
    prov_cnt_new = t1_upd_real_dir ? ((prov_cnt < 3'd7) ? (prov_cnt + 3'd1) : 3'd7)
                                   : ((prov_cnt > 3'd0) ? (prov_cnt - 3'd1) : 3'd0);
    prov_u_new   = prov_u;
    if (pdir != eff_alt) begin
      if (pdir == t1_upd_real_dir) prov_u_new = (prov_u < 2'd3) ? (prov_u + 2'd1) : 2'd3;
      else                         prov_u_new = (prov_u > 2'd0) ? (prov_u - 2'd1) : 2'd0;
    end
    base_cnt_new = t1_upd_real_dir ? ((upd_raw.base_cnt < 2'd3) ? (upd_raw.base_cnt + 2'd1) : 2'd3)
                                   : ((upd_raw.base_cnt > 2'd0) ? (upd_raw.base_cnt - 2'd1) : 2'd0);

    start_t = (eff_pcpn == PCPN_W'(TN)) ? 3'd0 : (eff_pcpn + 3'd1);
    nf      = 3'd0;
    free0   = 2'd0;
    free1   = 2'd0;
    for (int t = 0; t < TN; t++) begin
      if ((3'(t) >= start_t) && (upd_raw.useful[t] == 2'd0)) begin
        if (nf == 3'd0) free0 = 2'(t);
        if (nf == 3'd1) free1 = 2'(t);
        nf = nf + 3'd1;
      end
    end
    chosen_t = ((nf > 3'd1) && (lsfr_q[1:0] == 2'b00)) ? free1 : free0;
    do_alloc = t1_upd_en && (eff_pred != t1_upd_real_dir) && (nf != 3'd0);
    do_dec_u = t1_upd_en && (eff_pred != t1_upd_real_dir) && (nf == 3'd0);
  end

  // ---- Control state next values & periodic useful reset ----
  logic             rst_en;
  logic [IDX_W-1:0] rst_row;
  logic [3:0]       lsfr_nxt;

  always_comb begin
    lsfr_nxt    = {lsfr_q[2:0], lsfr_q[3] ^ lsfr_q[2]};
    lsfr_d      = t1_upd_en ? ((lsfr_nxt == 4'd0) ? 4'd1 : lsfr_nxt) : lsfr_q;
    reset_cnt_d = t1_upd_en ? (reset_cnt_q + 32'd1) : reset_cnt_q;
    rst_en      = t1_upd_en && (reset_cnt_d[FTB_URST_BITS-1:0] == '0);
    rst_row     = reset_cnt_d[FTB_URST_BITS +: IDX_W];

    use_alt_d = use_alt_q;
    if (t1_upd_en && (eff_pcpn < PCPN_W'(TN)) && is_weak && (pdir != eff_alt)) begin
      if (eff_alt == t1_upd_real_dir) begin
        if (use_alt_q > 4'd0)  use_alt_d = use_alt_q - 4'd1;
      end else begin
        if (use_alt_q < 4'd15) use_alt_d = use_alt_q + 4'd1;
      end
    end
  end

  // ---- Write port driving (strictly 1W; periodic rst_en takes priority on u_uhi) ----
  logic [1:0] dec_u;

  always_comb begin
    dec_u = 2'd0;
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      base_wr_e[sl] = HAS_BASE && t1_upd_en && (FTB_SLOT_W'(sl) == t1_upd_sl) && (eff_pcpn == PCPN_W'(TN));
      base_wr_a[sl] = t1_upd_ix.base_idx[IDX_W-1:0];
      base_wr_d[sl] = base_cnt_new;
      for (int t = 0; t < TN; t++) begin
        tc_wr_e[t][sl]  = 1'b0;
        tc_wr_a[t][sl]  = t1_upd_ix.idx[t][IDX_W-1:0];
        tc_wr_d[t][sl]  = '{tag: upd_raw.tag[t], cnt: prov_cnt_new};
        ulo_wr_e[t][sl] = 1'b0;
        ulo_wr_a[t][sl] = t1_upd_ix.idx[t][IDX_W-1:0];
        ulo_wr_d[t][sl] = 1'b0;
        uhi_wr_e[t][sl] = 1'b0;
        uhi_wr_a[t][sl] = t1_upd_ix.idx[t][IDX_W-1:0];
        uhi_wr_d[t][sl] = 1'b0;

        if (t1_upd_en && (FTB_SLOT_W'(sl) == t1_upd_sl)) begin
          if ((eff_pcpn < PCPN_W'(TN)) && (eff_pcpn[1:0] == 2'(t))) begin
            tc_wr_e[t][sl] = 1'b1;
            if (pdir != eff_alt) begin
              ulo_wr_e[t][sl] = 1'b1;
              ulo_wr_d[t][sl] = prov_u_new[0];
              uhi_wr_e[t][sl] = 1'b1;
              uhi_wr_d[t][sl] = prov_u_new[1];
            end
          end else if (do_alloc && (chosen_t == 2'(t))) begin
            tc_wr_e[t][sl]  = 1'b1;
            tc_wr_d[t][sl]  = '{tag: t1_upd_ix.tag[t], cnt: t1_upd_real_dir ? 3'd4 : 3'd3};
            ulo_wr_e[t][sl] = 1'b1;
            ulo_wr_d[t][sl] = 1'b0;
            uhi_wr_e[t][sl] = 1'b1;
            uhi_wr_d[t][sl] = 1'b0;
          end else if (do_dec_u && (3'(t) >= start_t) && (upd_raw.useful[t] > 2'd0)) begin
            dec_u           = upd_raw.useful[t] - 2'd1;
            ulo_wr_e[t][sl] = 1'b1;
            ulo_wr_d[t][sl] = dec_u[0];
            uhi_wr_e[t][sl] = 1'b1;
            uhi_wr_d[t][sl] = dec_u[1];
          end

          if (rst_en) begin
            uhi_wr_e[t][sl] = 1'b1;
            uhi_wr_a[t][sl] = rst_row;
            uhi_wr_d[t][sl] = 1'b0;
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lsfr_q      <= 4'd8;
      reset_cnt_q <= 32'd0;
      use_alt_q   <= FTB_USE_ALT_INIT;
    end else begin
      lsfr_q      <= lsfr_d;
      reset_cnt_q <= reset_cnt_d;
      use_alt_q   <= use_alt_d;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_tage;
  assign unused_tage = ^{t1_upd_pred_dir, t1_upd_alt_pred, t1_upd_pcpn, t1_upd_base_ctr, live_p.used_alt,
                         base_rd_e[0][0], base_rd_a[0][0], base_wr_e[0], base_wr_a[0], base_wr_d[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
