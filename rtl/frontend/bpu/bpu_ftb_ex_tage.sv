// Ref: front-end/BPU/BpuSc.h  struct ExBlockTage (4096x8x4 long-history S2 Block-TAGE, strict sync 1R1W SRAM)
`default_nettype none

module bpu_ftb_ex_tage import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                  clk,
  input  logic                  rst_n,
  // S1 dual sync read launch (Block A & Block B, all 4 slots; 1-cycle latency -> outputs directly feed S2)
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_ix_t           rd_ix,
  input  ex_tage_ix_t           rd2_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_tage_raw_t          rd_raw,
  output ex_tage_raw_t          rd2_raw,
  output logic [15:0][3:0]      use_alt_o,
  // T0 sync read launch for commit update (WF=1 WRITE_FIRST)
  input  logic                  t0_upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_ix_t           t0_upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  // T1 single-slot commit update execute & write (exports live pred to S2 SC)
  input  logic                  t1_upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_ix_t           t1_upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTB_SLOT_W-1:0] t1_upd_sl,
  input  logic                  t1_upd_real_dir,
  output logic                  upd_live_pred,
  output logic                  upd_live_prov_hit,
  output logic [2:0]            upd_live_prov_cnt,
  output logic [1:0]            upd_live_base_cnt
);

  localparam int IDX_W = $clog2(EX_TAGE_N);
  localparam int N_RD  = 3;
  localparam logic [2:0] WF_MASK = 3'b010; // port 0/2 predict = READ_FIRST, port 1 train = WRITE_FIRST

  typedef struct packed {
    logic [EX_TAGE_TAG_W-1:0] tag;
    logic [2:0]               cnt;
  } ex_tc_t;

  // ---- Control state registers ----
  logic [3:0]       lsfr_q, lsfr_d;
  logic [31:0]      reset_cnt_q, reset_cnt_d;
  logic [15:0][3:0] use_alt_q, use_alt_d;

  assign use_alt_o = use_alt_q;

  // ---- Backing strict sync 1R1W SRAMs ----
  logic             base_rd_e  [FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] base_rd_a  [FTB_SLOTS][N_RD];
  logic [1:0]       base_rd_d  [FTB_SLOTS][N_RD];
  logic             base_wr_e  [FTB_SLOTS];
  logic [IDX_W-1:0] base_wr_a  [FTB_SLOTS];
  logic [1:0]       base_wr_d  [FTB_SLOTS];

  logic             tc_rd_e    [EX_TN][FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] tc_rd_a    [EX_TN][FTB_SLOTS][N_RD];
  ex_tc_t           tc_rd_d    [EX_TN][FTB_SLOTS][N_RD];
  logic             tc_wr_e    [EX_TN][FTB_SLOTS];
  logic [IDX_W-1:0] tc_wr_a    [EX_TN][FTB_SLOTS];
  ex_tc_t           tc_wr_d    [EX_TN][FTB_SLOTS];

  logic             ulo_rd_e   [EX_TN][FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] ulo_rd_a   [EX_TN][FTB_SLOTS][N_RD];
  logic [0:0]       ulo_rd_d   [EX_TN][FTB_SLOTS][N_RD];
  logic             ulo_wr_e   [EX_TN][FTB_SLOTS];
  logic [IDX_W-1:0] ulo_wr_a   [EX_TN][FTB_SLOTS];
  logic [0:0]       ulo_wr_d   [EX_TN][FTB_SLOTS];

  logic             uhi_rd_e   [EX_TN][FTB_SLOTS][N_RD];
  logic [IDX_W-1:0] uhi_rd_a   [EX_TN][FTB_SLOTS][N_RD];
  logic [0:0]       uhi_rd_d   [EX_TN][FTB_SLOTS][N_RD];
  logic             uhi_wr_e   [EX_TN][FTB_SLOTS];
  logic [IDX_W-1:0] uhi_wr_a   [EX_TN][FTB_SLOTS];
  logic [0:0]       uhi_wr_d   [EX_TN][FTB_SLOTS];

  for (genvar sl = 0; sl < FTB_SLOTS; sl++) begin : g_sl
    bpu_sram_sync #(.W(2), .DEPTH(EX_TAGE_N), .N_RD(N_RD), .T(logic [1:0]), .INIT(2'd1), .WF_MASK(WF_MASK), .TAG("BPU_S2_TAGE_BASE")) u_base (
      .clk, .rd_en(base_rd_e[sl]), .rd_addr(base_rd_a[sl]), .rd_data(base_rd_d[sl]),
      .wr_en(base_wr_e[sl]), .wr_addr(base_wr_a[sl]), .wr_data(base_wr_d[sl])
    );
    for (genvar t = 0; t < EX_TN; t++) begin : g_tbl
      bpu_sram_sync #(.W($bits(ex_tc_t)), .DEPTH(EX_TAGE_N), .N_RD(N_RD), .T(ex_tc_t), .WF_MASK(WF_MASK), .TAG("BPU_S2_TAGE_TC")) u_tc (
        .clk, .rd_en(tc_rd_e[t][sl]), .rd_addr(tc_rd_a[t][sl]), .rd_data(tc_rd_d[t][sl]),
        .wr_en(tc_wr_e[t][sl]), .wr_addr(tc_wr_a[t][sl]), .wr_data(tc_wr_d[t][sl])
      );
      bpu_sram_sync #(.W(1), .DEPTH(EX_TAGE_N), .N_RD(N_RD), .WF_MASK(WF_MASK), .TAG("BPU_S2_TAGE_ULO")) u_ulo (
        .clk, .rd_en(ulo_rd_e[t][sl]), .rd_addr(ulo_rd_a[t][sl]), .rd_data(ulo_rd_d[t][sl]),
        .wr_en(ulo_wr_e[t][sl]), .wr_addr(ulo_wr_a[t][sl]), .wr_data(ulo_wr_d[t][sl])
      );
      bpu_sram_sync #(.W(1), .DEPTH(EX_TAGE_N), .N_RD(N_RD), .WF_MASK(WF_MASK), .TAG("BPU_S2_TAGE_UHI")) u_uhi (
        .clk, .rd_en(uhi_rd_e[t][sl]), .rd_addr(uhi_rd_a[t][sl]), .rd_data(uhi_rd_d[t][sl]),
        .wr_en(uhi_wr_e[t][sl]), .wr_addr(uhi_wr_a[t][sl]), .wr_data(uhi_wr_d[t][sl])
      );
    end
  end

  // ---- Read ports & predict raw assembly ----
  ex_tage_slot_raw_t upd_raw;

  always_comb begin
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      base_rd_e[sl][0]     = 1'b1;
      base_rd_e[sl][1]     = t0_upd_en;
      base_rd_e[sl][2]     = 1'b1;
      base_rd_a[sl][0]     = rd_ix.base_idx;
      base_rd_a[sl][1]     = t0_upd_ix.base_idx;
      base_rd_a[sl][2]     = rd2_ix.base_idx;
      rd_raw[sl].base_cnt  = base_rd_d[sl][0];
      rd2_raw[sl].base_cnt = base_rd_d[sl][2];
      for (int t = 0; t < EX_TN; t++) begin
        tc_rd_e[t][sl][0]     = 1'b1;
        tc_rd_e[t][sl][1]     = t0_upd_en;
        tc_rd_e[t][sl][2]     = 1'b1;
        tc_rd_a[t][sl][0]     = rd_ix.idx[t];
        tc_rd_a[t][sl][1]     = t0_upd_ix.idx[t];
        tc_rd_a[t][sl][2]     = rd2_ix.idx[t];
        ulo_rd_e[t][sl][0]    = 1'b1;
        ulo_rd_e[t][sl][1]    = t0_upd_en;
        ulo_rd_e[t][sl][2]    = 1'b1;
        ulo_rd_a[t][sl][0]    = rd_ix.idx[t];
        ulo_rd_a[t][sl][1]    = t0_upd_ix.idx[t];
        ulo_rd_a[t][sl][2]    = rd2_ix.idx[t];
        uhi_rd_e[t][sl][0]    = 1'b1;
        uhi_rd_e[t][sl][1]    = t0_upd_en;
        uhi_rd_e[t][sl][2]    = 1'b1;
        uhi_rd_a[t][sl][0]    = rd_ix.idx[t];
        uhi_rd_a[t][sl][1]    = t0_upd_ix.idx[t];
        uhi_rd_a[t][sl][2]    = rd2_ix.idx[t];
        rd_raw[sl].tag[t]     = tc_rd_d[t][sl][0].tag;
        rd_raw[sl].cnt[t]     = tc_rd_d[t][sl][0].cnt;
        rd_raw[sl].useful[t]  = {uhi_rd_d[t][sl][0], ulo_rd_d[t][sl][0]};
        rd2_raw[sl].tag[t]    = tc_rd_d[t][sl][2].tag;
        rd2_raw[sl].cnt[t]    = tc_rd_d[t][sl][2].cnt;
        rd2_raw[sl].useful[t] = {uhi_rd_d[t][sl][2], ulo_rd_d[t][sl][2]};
      end
    end

    upd_raw.base_cnt = base_rd_d[t1_upd_sl][1];
    for (int t = 0; t < EX_TN; t++) begin
      upd_raw.tag[t]    = tc_rd_d[t][t1_upd_sl][1].tag;
      upd_raw.cnt[t]    = tc_rd_d[t][t1_upd_sl][1].cnt;
      upd_raw.useful[t] = {uhi_rd_d[t][t1_upd_sl][1], ulo_rd_d[t][t1_upd_sl][1]};
    end
  end

  // ---- T1 Live prediction metadata & allocation target ----
  ex_tage_pred_t live_p;
  logic          pdir, is_weak;
  logic [3:0]    eff_pcpn, start_t, nf;
  logic [2:0]    prov_cnt, prov_cnt_new, free0, free1, chosen_t;
  logic [1:0]    prov_u, prov_u_new, base_cnt_new;
  logic          do_alloc, do_dec_u;

  always_comb begin
    live_p            = ex_tage_select(t1_upd_ix, upd_raw, use_alt_q);
    upd_live_pred     = live_p.pred;
    upd_live_prov_hit = (live_p.pcpn < 4'(EX_TN));
    upd_live_prov_cnt = live_p.prov_cnt;
    upd_live_base_cnt = live_p.base_cnt;

    eff_pcpn     = live_p.pcpn;
    prov_cnt     = (eff_pcpn < 4'(EX_TN)) ? upd_raw.cnt[eff_pcpn[2:0]]    : 3'd0;
    prov_u       = (eff_pcpn < 4'(EX_TN)) ? upd_raw.useful[eff_pcpn[2:0]] : 2'd0;
    pdir         = (prov_cnt >= 3'd4);
    is_weak      = (prov_cnt == 3'd3) || (prov_cnt == 3'd4);
    prov_cnt_new = t1_upd_real_dir ? ((prov_cnt < 3'd7) ? (prov_cnt + 3'd1) : 3'd7)
                                   : ((prov_cnt > 3'd0) ? (prov_cnt - 3'd1) : 3'd0);
    prov_u_new   = prov_u;
    if (pdir != live_p.alt) begin
      if (pdir == t1_upd_real_dir) prov_u_new = (prov_u < 2'd3) ? (prov_u + 2'd1) : 2'd3;
      else                         prov_u_new = (prov_u > 2'd0) ? (prov_u - 2'd1) : 2'd0;
    end
    base_cnt_new = t1_upd_real_dir ? ((upd_raw.base_cnt < 2'd3) ? (upd_raw.base_cnt + 2'd1) : 2'd3)
                                   : ((upd_raw.base_cnt > 2'd0) ? (upd_raw.base_cnt - 2'd1) : 2'd0);

    start_t = (eff_pcpn == 4'(EX_TN)) ? 4'd0 : (eff_pcpn + 4'd1);
    nf      = 4'd0;
    free0   = 3'd0;
    free1   = 3'd0;
    for (int t = 0; t < EX_TN; t++) begin
      if ((4'(t) >= start_t) && (upd_raw.useful[t] == 2'd0)) begin
        if (nf == 4'd0) free0 = 3'(t);
        if (nf == 4'd1) free1 = 3'(t);
        nf = nf + 4'd1;
      end
    end
    chosen_t = ((nf > 4'd1) && (lsfr_q[1:0] == 2'b00)) ? free1 : free0;
    do_alloc = t1_upd_en && (live_p.pred != t1_upd_real_dir) && (nf != 4'd0);
    do_dec_u = t1_upd_en && (live_p.pred != t1_upd_real_dir) && (nf == 4'd0);
  end

  // ---- Control state next values & periodic useful reset ----
  logic             rst_en;
  logic [IDX_W-1:0] rst_row;
  logic [3:0]       lsfr_nxt, ua_idx, ua_cur;

  always_comb begin
    lsfr_nxt    = {lsfr_q[2:0], lsfr_q[3] ^ lsfr_q[2]};
    lsfr_d      = t1_upd_en ? ((lsfr_nxt == 4'd0) ? 4'd1 : lsfr_nxt) : lsfr_q;
    reset_cnt_d = t1_upd_en ? (reset_cnt_q + 32'd1) : reset_cnt_q;
    rst_en      = t1_upd_en && (reset_cnt_d[EX_TAGE_URST-1:0] == '0);
    rst_row     = reset_cnt_d[EX_TAGE_URST +: IDX_W];

    ua_idx    = t1_upd_ix.w[5:2];
    ua_cur    = use_alt_q[ua_idx];
    use_alt_d = use_alt_q;
    if (t1_upd_en && (eff_pcpn < 4'(EX_TN)) && is_weak && (pdir != live_p.alt)) begin
      if (live_p.alt == t1_upd_real_dir) begin
        if (ua_cur > 4'd0)  use_alt_d[ua_idx] = ua_cur - 4'd1;
      end else begin
        if (ua_cur < 4'd15) use_alt_d[ua_idx] = ua_cur + 4'd1;
      end
    end
  end

  // ---- Write port driving (strictly 1W; periodic rst_en takes priority on u_uhi) ----
  logic [1:0] dec_u;

  always_comb begin
    dec_u = 2'd0;
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      base_wr_e[sl] = t1_upd_en && (FTB_SLOT_W'(sl) == t1_upd_sl) && (eff_pcpn == 4'(EX_TN));
      base_wr_a[sl] = t1_upd_ix.base_idx;
      base_wr_d[sl] = base_cnt_new;
      for (int t = 0; t < EX_TN; t++) begin
        tc_wr_e[t][sl]  = 1'b0;
        tc_wr_a[t][sl]  = t1_upd_ix.idx[t];
        tc_wr_d[t][sl]  = '{tag: upd_raw.tag[t], cnt: prov_cnt_new};
        ulo_wr_e[t][sl] = 1'b0;
        ulo_wr_a[t][sl] = t1_upd_ix.idx[t];
        ulo_wr_d[t][sl] = 1'b0;
        uhi_wr_e[t][sl] = 1'b0;
        uhi_wr_a[t][sl] = t1_upd_ix.idx[t];
        uhi_wr_d[t][sl] = 1'b0;

        if (t1_upd_en && (FTB_SLOT_W'(sl) == t1_upd_sl)) begin
          if ((eff_pcpn < 4'(EX_TN)) && (eff_pcpn[2:0] == 3'(t))) begin
            tc_wr_e[t][sl] = 1'b1;
            if (pdir != live_p.alt) begin
              ulo_wr_e[t][sl] = 1'b1;
              ulo_wr_d[t][sl] = prov_u_new[0];
              uhi_wr_e[t][sl] = 1'b1;
              uhi_wr_d[t][sl] = prov_u_new[1];
            end
          end else if (do_alloc && (chosen_t == 3'(t))) begin
            tc_wr_e[t][sl]  = 1'b1;
            tc_wr_d[t][sl]  = '{tag: t1_upd_ix.tag[t], cnt: t1_upd_real_dir ? 3'd4 : 3'd3};
            ulo_wr_e[t][sl] = 1'b1;
            ulo_wr_d[t][sl] = 1'b0;
            uhi_wr_e[t][sl] = 1'b1;
            uhi_wr_d[t][sl] = 1'b0;
          end else if (do_dec_u && (4'(t) >= start_t) && (upd_raw.useful[t] > 2'd0)) begin
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
      for (int i = 0; i < 16; i++) use_alt_q[i] <= FTB_USE_ALT_INIT;
    end else begin
      lsfr_q      <= lsfr_d;
      reset_cnt_q <= reset_cnt_d;
      use_alt_q   <= use_alt_d;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ex_tage;
  assign unused_ex_tage = live_p.used_alt;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
