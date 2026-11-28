// Ref: front-end/BPU/BpuSc.h  struct ExBlockTage (2-Way 6-table 2-Ahead, 4-Bank 512x128b 1RW, no base SRAM)
`default_nettype none

module bpu_ftb_ex_tage import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                  clk,
  input  logic                  rst_n,
  // A0 sync read launch (write-wins rd_sup enforces conflict-free 4-Bank 1RW, HOLD_RD0=1)
  input  logic                  rd_en,
  input  logic [EX_TN-1:0]      rd_sup,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_ix_t           rd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_tage_raw_t          rd_raw,
  output logic [15:0][3:0]      use_alt_o,
  // Single-cycle pure commit write (Meta + WRBypass; base comes from u_ftb1 ctr)
  input  logic                  upd_en,
  input  ex_tage_ix_t           upd_ix,
  input  logic [FTB_SLOT_W-1:0] upd_sl,
  input  logic                  upd_real_dir,
  input  logic [1:0]            upd_base_ctr,
  input  logic                  upd_meta_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_slot_meta_t    upd_meta,
  /* verilator lint_on UNUSEDSIGNAL */
  // Combinational write masks exported to bpu_ftb_arrays for write-wins arbitration
  output logic [EX_TN-1:0]      tbl_wr_mask_o,
  // Per-table 4-bit busy masks (wr | rd0) for deferred 1RW uhi periodic reset
  input  logic [EX_TN-1:0][BPU_AH_TAGE_BANKS-1:0] tbl_busy_mask
);

  localparam int IDX_W     = EX_TAGE_IDX_W;             // 11 (2048 sets)
  localparam int WRB_IDX_W = IDX_W + 1;                 // 12 ({row_idx[10:0], way})
  localparam int TBL_W     = FTB_SLOTS * 32;            // 128b = 4 slots x 2 ways x 16b

  // ---- Control state registers + per-table deferred 1RW uhi reset ----
  logic [3:0]            lsfr_q, lsfr_d;
  logic [31:0]           reset_cnt_q, reset_cnt_d;
  logic [15:0][3:0]      use_alt_q, use_alt_d;
  logic [EX_TN-1:0]      rst_pend_q, rst_pend_d;
  logic [IDX_W-1:0]      rst_row_q, rst_row_d;
  logic [FTB_SLOT_W-1:0] rst_sl_q, rst_sl_d;

  assign use_alt_o = use_alt_q;

  // ---- Inline 8-entry FF WRBypass (keyed by {tbl, sl, row_idx, way}) ----
  typedef struct packed {
    logic                 valid;
    logic [2:0]           tbl;
    logic [1:0]           sl;
    logic [WRB_IDX_W-1:0] idx;
    logic [2:0]           cnt;
    logic [1:0]           u;
  } wrb_ent_t;

  wrb_ent_t wrb_q [BPU_WRB_N];
  logic [2:0] wrb_ptr_q;

  function automatic logic [5:0] wrb_lookup(input logic [2:0] tbl, input logic [1:0] sl,
                                            input logic [IDX_W-1:0] row_i, input logic way);
    logic [WRB_IDX_W-1:0] key_i;
    key_i = {row_i, way};
    for (int i = 0; i < BPU_WRB_N; i++) begin
      if (wrb_q[i].valid && (wrb_q[i].tbl == tbl) && (wrb_q[i].sl == sl) && (wrb_q[i].idx == key_i))
        return {1'b1, wrb_q[i].u, wrb_q[i].cnt};
    end
    return 6'd0;
  endfunction

  // ---- Stage 1 of commit plan: provider read + candidate useful evaluation ----
  logic [3:0]       eff_pcpn, start_t, nf;
  logic             eff_pw, eff_alt, eff_pred, pdir, is_weak, prov_wr_req;
  logic [1:0]       prov_u, prov_u_new;
  logic [2:0]       prov_cnt, prov_cnt_new, free0, free1, chosen_t;
  logic [EX_TN-1:0] free_w;
  logic [1:0]       u_eff [EX_TN][EX_TAGE_WAYS];

  always_comb begin
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] lk_p, lk_t;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0] nz_w;
    logic       c_w;

    eff_pcpn = upd_meta_valid ? upd_meta.pcpn : 4'(EX_TN);
    eff_pw   = upd_meta_valid ? upd_meta.prov_way : 1'b0;
    eff_alt  = upd_meta_valid ? upd_meta.alt : upd_base_ctr[1];
    eff_pred = upd_meta_valid ? upd_meta.pred : upd_base_ctr[1];

    lk_p     = (eff_pcpn < 4'(EX_TN))
               ? wrb_lookup(eff_pcpn[2:0], upd_sl, upd_ix.idx[eff_pcpn[2:0]], eff_pw) : 6'd0;
    prov_cnt = (eff_pcpn < 4'(EX_TN))
               ? (lk_p[5] ? lk_p[2:0] : (upd_meta_valid ? upd_meta.prov_cnt : {1'b0, upd_base_ctr}))
               : {1'b0, upd_base_ctr};
    prov_u   = (eff_pcpn < 4'(EX_TN))
               ? (lk_p[5] ? lk_p[4:3] : (upd_meta_valid ? upd_meta.prov_u : 2'd0))
               : 2'd0;

    pdir         = prov_cnt[2];
    is_weak      = (prov_cnt == 3'd3) || (prov_cnt == 3'd4);
    prov_cnt_new = upd_real_dir ? ((prov_cnt < 3'd7) ? (prov_cnt + 3'd1) : 3'd7)
                                : ((prov_cnt > 3'd0) ? (prov_cnt - 3'd1) : 3'd0);
    prov_u_new   = prov_u;
    if (pdir != eff_alt) begin
      if (pdir == upd_real_dir) prov_u_new = (prov_u < 2'd3) ? (prov_u + 2'd1) : 2'd3;
      else                      prov_u_new = (prov_u > 2'd0) ? (prov_u - 2'd1) : 2'd0;
    end
    prov_wr_req = upd_en && (eff_pcpn < 4'(EX_TN)) && ((prov_cnt_new != prov_cnt) || (prov_u_new != prov_u));

    start_t = (eff_pcpn == 4'(EX_TN)) ? 4'd0 : (eff_pcpn + 4'd1);
    nf = 4'd0; free0 = 3'd0; free1 = 3'd0; free_w = '0;
    for (int t = 0; t < EX_TN; t++) begin
      nz_w = 2'b00;
      for (int w = 0; w < EX_TAGE_WAYS; w++) begin
        lk_t          = wrb_lookup(3'(t), upd_sl, upd_ix.idx[t], 1'(w));
        u_eff[t][w]   = lk_t[5] ? lk_t[4:3] : (upd_meta_valid ? upd_meta.useful[t][w] : 2'd0);
        nz_w[w]       = (u_eff[t][w] == 2'd0);
      end
      c_w       = (nz_w == 2'b11) ? lsfr_q[0] : (nz_w[0] ? 1'b0 : 1'b1);
      free_w[t] = c_w;
      if ((4'(t) >= start_t) && (|nz_w)) begin
        if (nf == 4'd0) free0 = 3'(t);
        if (nf == 4'd1) free1 = 3'(t);
        nf = nf + 4'd1;
      end
    end
    chosen_t = ((nf > 4'd1) && (lsfr_q[1:0] == 2'b00)) ? free1 : free0;
  end

  // ---- Stage 2 of commit plan: per-table write masks & new values ----
  logic             do_alloc, do_dec_u;
  logic [EX_TN-1:0] tbl_wr_mask, tbl_is_alloc, tbl_way;
  logic [2:0]       tbl_cnt_new [EX_TN];
  logic [1:0]       tbl_u_new   [EX_TN];

  always_comb begin
    logic dw;
    do_alloc = upd_en && (!upd_meta_valid || (eff_pred != upd_real_dir)) && (nf != 4'd0);
    do_dec_u = upd_en && (!upd_meta_valid || (eff_pred != upd_real_dir)) && (nf == 4'd0);

    tbl_wr_mask  = '0;
    tbl_is_alloc = '0;
    tbl_way      = '0;
    for (int t = 0; t < EX_TN; t++) begin
      tbl_cnt_new[t] = 3'd0;
      tbl_u_new[t]   = 2'd0;
      dw             = (u_eff[t][1] < u_eff[t][0]) ? 1'b1 : 1'b0;
      if (u_eff[t][dw] == 2'd0) dw = ~dw;
      if (prov_wr_req && (eff_pcpn[2:0] == 3'(t))) begin
        tbl_wr_mask[t] = 1'b1;
        tbl_way[t]     = eff_pw;
        tbl_cnt_new[t] = prov_cnt_new;
        tbl_u_new[t]   = prov_u_new;
      end else if (do_alloc && (chosen_t == 3'(t))) begin
        tbl_wr_mask[t]  = 1'b1;
        tbl_is_alloc[t] = 1'b1;
        tbl_way[t]      = free_w[t];
        tbl_cnt_new[t]  = upd_real_dir ? 3'd4 : 3'd3;
        tbl_u_new[t]    = 2'd0;
      end else if (do_dec_u && (4'(t) >= start_t) && (u_eff[t][dw] != 2'd0)) begin
        tbl_wr_mask[t] = 1'b1;
        tbl_way[t]     = dw;
        tbl_u_new[t]   = u_eff[t][dw] - 2'd1;
      end
    end
    tbl_wr_mask_o = tbl_wr_mask;
  end

  // ---- Packed 4-Bank u_tbl[0..5] 1RW SRAMs (512 deep x 128b -> 48 x 512x72 macros) ----
  logic [TBL_W-1:0]      tbl_rd0  [EX_TN];
  logic [TBL_W-1:0]      tbl_wr_d [EX_TN];
  logic [TBL_W-1:0]      tbl_wr_m [EX_TN];
  logic                  rst_en;
  logic [EX_TN-1:0]      rst_pend_eff, rst_fire, rd0_sup_q;
  logic [IDX_W-1:0]      rst_row_eff;
  logic [FTB_SLOT_W-1:0] rst_sl_eff;
  logic [TBL_W-1:0]      rst_wmask;

  assign reset_cnt_d  = upd_en ? (reset_cnt_q + 32'd1) : reset_cnt_q;
  assign rst_en       = upd_en && (reset_cnt_d[EX_TAGE_URST-1:0] == '0);
  assign rst_pend_eff = rst_en ? {EX_TN{1'b1}} : rst_pend_q;
  assign rst_row_eff  = rst_en ? reset_cnt_d[EX_TAGE_URST +: IDX_W] : rst_row_q;
  assign rst_sl_eff   = rst_en ? upd_sl : rst_sl_q;
  assign rst_wmask    = (TBL_W'(1) << {rst_sl_eff, 5'd15}) | (TBL_W'(1) << {rst_sl_eff, 5'd31});

  always_comb begin
    for (int t = 0; t < EX_TN; t++) begin
      logic [15:0] lane_d, lane_m;
      rst_fire[t] = rst_pend_eff[t] && !tbl_busy_mask[t][rst_row_eff[1:0]];
      lane_d      = 16'd0;
      lane_m      = 16'd0;
      if (tbl_wr_mask[t]) begin
        if (tbl_is_alloc[t]) begin
          lane_d = {tbl_u_new[t], upd_ix.tag[t], tbl_cnt_new[t]};
          lane_m = 16'hffff;
        end else if (prov_wr_req && (eff_pcpn[2:0] == 3'(t))) begin
          lane_d = {tbl_u_new[t], 11'd0, tbl_cnt_new[t]};
          lane_m = 16'hc007;
        end else begin
          lane_d = {tbl_u_new[t], 14'd0};
          lane_m = 16'hc000;
        end
      end
      tbl_wr_d[t] = {8{lane_d}};
      tbl_wr_m[t] = {{(TBL_W-16){1'b0}}, lane_m} << {upd_sl, tbl_way[t], 4'd0};
    end
  end

  for (genvar t = 0; t < EX_TN; t++) begin : g_tbl
    bpu_sram_1rw_banked #(
      .W       (TBL_W),
      .DEPTH   (EX_TAGE_SETS),
      .NB      (BPU_AH_TAGE_BANKS),
      .MASK_W  (TBL_W),
      .HAS_RST (1'b1),
      .HOLD_RD0(1'b1),
      .INIT    ({TBL_W{1'b0}}),
      .TAG     ("BPU_AH_EX_TAGE")
    ) u_tbl (
      .clk         (clk),
      .rst_n       (rst_n),
      .rd0_en      (rd_en && !rd_sup[t]),
      .rd0_addr    (rd_ix.idx[t]),
      .rd0_data    (tbl_rd0[t]),
      .clr_rd_en   (1'b0),
      .clr_rd_addr ('0),
      /* verilator lint_off PINCONNECTEMPTY */
      .clr_rd_data (),
      /* verilator lint_on PINCONNECTEMPTY */
      .wr_en       (tbl_wr_mask[t]),
      .wr_addr     (upd_ix.idx[t]),
      .wr_data     (tbl_wr_d[t]),
      .wr_wmask    (tbl_wr_m[t]),
      .rst_wr_en   (rst_fire[t]),
      .rst_wr_addr (rst_row_eff),
      .rst_wr_data ({TBL_W{1'b0}}),
      .rst_wr_wmask(rst_wmask)
    );
  end

  // ---- Unpack predict raw ----
  always_comb begin
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      rd_raw[sl].sup_mask = rd0_sup_q;
      for (int t = 0; t < EX_TN; t++) begin
        for (int w = 0; w < EX_TAGE_WAYS; w++) begin
          logic [15:0] e0;
          e0 = tbl_rd0[t][sl * 32 + w * 16 +: 16];
          if (rd0_sup_q[t]) begin
            rd_raw[sl].cnt[t][w]    = 3'd0;
            rd_raw[sl].tag[t][w]    = '0;
            rd_raw[sl].useful[t][w] = 2'd1;
          end else begin
            rd_raw[sl].cnt[t][w]    = e0[2:0];
            rd_raw[sl].tag[t][w]    = e0[13:3];
            rd_raw[sl].useful[t][w] = e0[15:14];
          end
        end
      end
    end
  end

  // ---- Control state & WRBypass updates ----
  logic [3:0] lsfr_nxt, ua_idx, ua_cur;

  always_comb begin
    lsfr_nxt   = {lsfr_q[2:0], lsfr_q[3] ^ lsfr_q[2]};
    lsfr_d     = upd_en ? ((lsfr_nxt == 4'd0) ? 4'd1 : lsfr_nxt) : lsfr_q;
    rst_pend_d = rst_pend_eff & ~rst_fire;
    rst_row_d  = rst_row_eff;
    rst_sl_d   = rst_sl_eff;
    ua_idx     = upd_ix.w[5:2];
    ua_cur     = use_alt_q[ua_idx];
    use_alt_d  = use_alt_q;
    if (upd_en && (eff_pcpn < 4'(EX_TN)) && is_weak && (pdir != eff_alt)) begin
      if (eff_alt == upd_real_dir) begin
        if (ua_cur > 4'd0)  use_alt_d[ua_idx] = ua_cur - 4'd1;
      end else begin
        if (ua_cur < 4'd15) use_alt_d[ua_idx] = ua_cur + 4'd1;
      end
    end
  end

  wrb_ent_t   wrb_d [BPU_WRB_N];
  logic [2:0] wrb_ptr_d;

  always_comb begin
    logic                 hit1, hit2;
    logic [2:0]           h1_i, h2_i, p;
    logic [WRB_IDX_W-1:0] pk, ak;
    hit1 = 1'b0; h1_i = 3'd0; hit2 = 1'b0; h2_i = 3'd0;
    for (int i = 0; i < BPU_WRB_N; i++) wrb_d[i] = wrb_q[i];
    p  = wrb_ptr_q;
    pk = {upd_ix.idx[eff_pcpn[2:0]], eff_pw};
    ak = {upd_ix.idx[chosen_t], free_w[chosen_t]};
    if (prov_wr_req) begin
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit1 && wrb_d[i].valid && (wrb_d[i].tbl == eff_pcpn[2:0]) &&
            (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == pk)) begin
          hit1 = 1'b1; h1_i = 3'(i);
        end
      if (hit1) begin
        wrb_d[h1_i].cnt = prov_cnt_new;
        wrb_d[h1_i].u   = prov_u_new;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: eff_pcpn[2:0], sl: upd_sl, idx: pk, cnt: prov_cnt_new, u: prov_u_new};
        p = p + 3'd1;
      end
    end
    if (do_alloc) begin
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit2 && wrb_d[i].valid && (wrb_d[i].tbl == chosen_t) &&
            (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == ak)) begin
          hit2 = 1'b1; h2_i = 3'(i);
        end
      if (hit2) begin
        wrb_d[h2_i].cnt = upd_real_dir ? 3'd4 : 3'd3;
        wrb_d[h2_i].u   = 2'd0;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: chosen_t, sl: upd_sl, idx: ak,
                     cnt: upd_real_dir ? 3'd4 : 3'd3, u: 2'd0};
        p = p + 3'd1;
      end
    end
    wrb_ptr_d = p;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lsfr_q <= 4'd8; reset_cnt_q <= 32'd0; rst_pend_q <= '0; rst_row_q <= '0;
      rst_sl_q <= '0; rd0_sup_q <= '0; wrb_ptr_q <= 3'd0;
      for (int i = 0; i < 16; i++) use_alt_q[i] <= FTB_USE_ALT_INIT;
      for (int i = 0; i < BPU_WRB_N; i++) wrb_q[i] <= '0;
    end else begin
      lsfr_q <= lsfr_d; reset_cnt_q <= reset_cnt_d;
      rst_pend_q <= rst_pend_d; rst_row_q <= rst_row_d; rst_sl_q <= rst_sl_d;
      if (rd_en) rd0_sup_q <= rd_sup;
      wrb_ptr_q <= wrb_ptr_d;
      use_alt_q <= use_alt_d;
      for (int i = 0; i < BPU_WRB_N; i++) wrb_q[i] <= wrb_d[i];
    end
  end

endmodule
`default_nettype wire
