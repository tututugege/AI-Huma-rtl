// Ref: front-end/BPU/BpuFtb.h  struct BlockTage (v10: Zero-T0-Read Meta + 8-entry FF WRBypass + 2-Bank 1RW)
//   - u_tbl[0..3]: 4 tables x 2 banks x ((N_ENT/2) x 60b) 1RW (4 slots x {uhi, ulo, tag[9:0], cnt[2:0]}, MASK_W=60)
//   - Zero T0 read ports! Commit computes write plan from ftb_rec Meta + inline 8-entry FF WRBypass.
`default_nettype none

module bpu_ftb_tage import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    N_ENT = 1024,
  parameter int    NB    = BPU_AH1_BANKS,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG  = "BPU_ATAGE"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                  clk,
  input  logic                  rst_n,
  // Predict sync read launch (write-wins rd_sup enforces conflict-free 2-Bank 1RW)
  input  logic                  rd_en,
  input  logic [TN-1:0]         rd_sup,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t               rd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ftb_tage_raw_t         rd_raw,
  output logic                  prefer_alt,
  // Single-cycle pure commit write (computed from ftb_rec Meta + WRBypass; ZERO T0 read!)
  input  logic                  upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t               upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTB_SLOT_W-1:0] upd_sl,
  input  logic                  upd_real_dir,
  input  logic [1:0]            upd_base_ctr,
  input  logic                  upd_meta_valid,
  input  ah_tage_slot_meta_t    upd_meta,
  // Combinational write mask exported to bpu_ftb_arrays for 2-bank write-wins arbitration
  output logic [TN-1:0]         tbl_wr_mask_o,
  // Per-table NB-bit busy masks (wr | rd0) for deferred 1RW uhi periodic reset
  input  logic [TN-1:0][NB-1:0] tbl_busy_mask
);

  localparam int IDX_W = $clog2(N_ENT);
  localparam int BK_W  = (NB > 1) ? $clog2(NB) : 1;

  // ---- Control state registers + per-table deferred 1RW uhi reset ----
  logic [3:0]            lsfr_q, lsfr_d;
  logic [31:0]           reset_cnt_q, reset_cnt_d;
  logic [3:0]            use_alt_q, use_alt_d;
  logic [TN-1:0]         rst_pend_q, rst_pend_d;
  logic [IDX_W-1:0]      rst_row_q, rst_row_d;
  logic [FTB_SLOT_W-1:0] rst_sl_q, rst_sl_d;

  assign prefer_alt = (use_alt_q <= FTB_USE_ALT_THR);

  // ---- Inline 8-entry FF WRBypass ----
  typedef struct packed {
    logic             valid;
    logic [1:0]       tbl;
    logic [1:0]       sl;
    logic [IDX_W-1:0] idx;
    logic [2:0]       cnt;
    logic [1:0]       u;
  } wrb_ent_t;

  wrb_ent_t wrb_q [BPU_WRB_N];
  logic [2:0] wrb_ptr_q;

  function automatic logic [5:0] wrb_lookup(input logic [1:0] tbl, input logic [1:0] sl, input logic [IDX_W-1:0] idx);
    for (int i = 0; i < BPU_WRB_N; i++) begin
      if (wrb_q[i].valid && (wrb_q[i].tbl == tbl) && (wrb_q[i].sl == sl) && (wrb_q[i].idx == idx))
        return {1'b1, wrb_q[i].u, wrb_q[i].cnt};
    end
    return 6'd0;
  endfunction

  // ---- Pure-combinational commit write plan from Meta + WRBypass ----
  logic [2:0]  eff_pcpn, start_t, nf;
  logic        bp, eff_alt, eff_pred, pdir, is_weak;
  logic [2:0]  prov_cnt, prov_cnt_new;
  logic [1:0]  prov_u, prov_u_new, free0, free1, chosen_t;
  logic [1:0]  u_eff [TN];
  logic        prov_wr_req, do_alloc, do_dec_u;
  logic [TN-1:0] tbl_wr_mask, tbl_is_alloc;
  logic [2:0]  tbl_cnt_new [TN];
  logic [1:0]  tbl_u_new   [TN];

  always_comb begin
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] lk_p, lk_t;
    /* verilator lint_on UNUSEDSIGNAL */

    eff_pcpn = upd_meta_valid ? upd_meta.pcpn : 3'(TN);
    bp       = (upd_base_ctr >= 2'd2);
    eff_alt  = upd_meta_valid ? upd_meta.alt  : bp;
    eff_pred = upd_meta_valid ? upd_meta.pred : bp;

    lk_p     = (eff_pcpn < 3'(TN)) ? wrb_lookup(eff_pcpn[1:0], upd_sl, upd_ix.idx[eff_pcpn[1:0]][IDX_W-1:0]) : 6'd0;
    prov_cnt = (eff_pcpn < 3'(TN)) ? (lk_p[5] ? lk_p[2:0] : upd_meta.prov_cnt) : 3'd0;
    prov_u   = (eff_pcpn < 3'(TN)) ? (lk_p[5] ? lk_p[4:3] : upd_meta.prov_u)   : 2'd0;

    pdir         = (prov_cnt >= 3'd4);
    is_weak      = (prov_cnt == 3'd3);
    prov_cnt_new = upd_real_dir ? ((prov_cnt < 3'd7) ? (prov_cnt + 3'd1) : 3'd7)
                                : ((prov_cnt > 3'd0) ? (prov_cnt - 3'd1) : 3'd0);
    prov_u_new   = prov_u;
    if (pdir != eff_alt) begin
      if (pdir == upd_real_dir) prov_u_new = (prov_u < 2'd3) ? (prov_u + 2'd1) : 2'd3;
      else                      prov_u_new = (prov_u > 2'd0) ? (prov_u - 2'd1) : 2'd0;
    end
    prov_wr_req = upd_en && (eff_pcpn < 3'(TN)) && ((prov_cnt_new != prov_cnt) || (prov_u_new != prov_u));

    start_t = (eff_pcpn == 3'(TN)) ? 3'd0 : (eff_pcpn + 3'd1);
    nf      = 3'd0;
    free0   = 2'd0;
    free1   = 2'd0;
    for (int t = 0; t < TN; t++) begin
      lk_t     = wrb_lookup(2'(t), upd_sl, upd_ix.idx[t][IDX_W-1:0]);
      u_eff[t] = lk_t[5] ? lk_t[4:3] : (upd_meta_valid ? upd_meta.useful[t] : 2'd0);
      if ((3'(t) >= start_t) && (u_eff[t] == 2'd0)) begin
        if (nf == 3'd0) free0 = 2'(t);
        if (nf == 3'd1) free1 = 2'(t);
        nf = nf + 3'd1;
      end
    end
    chosen_t = ((nf > 3'd1) && (lsfr_q[1:0] == 2'b00)) ? free1 : free0;
    do_alloc = upd_en && (!upd_meta_valid || (eff_pred != upd_real_dir)) && (nf != 3'd0);
    do_dec_u = upd_en && (!upd_meta_valid || (eff_pred != upd_real_dir)) && (nf == 3'd0);

    tbl_wr_mask  = '0;
    tbl_is_alloc = '0;
    for (int t = 0; t < TN; t++) begin
      tbl_cnt_new[t] = 3'd0;
      tbl_u_new[t]   = 2'd0;
      if (prov_wr_req && (eff_pcpn[1:0] == 2'(t))) begin
        tbl_wr_mask[t] = 1'b1;
        tbl_cnt_new[t] = prov_cnt_new;
        tbl_u_new[t]   = prov_u_new;
      end else if (do_alloc && (chosen_t == 2'(t))) begin
        tbl_wr_mask[t]  = 1'b1;
        tbl_is_alloc[t] = 1'b1;
        tbl_cnt_new[t]  = upd_real_dir ? 3'd4 : 3'd3;
        tbl_u_new[t]    = 2'd0;
      end else if (do_dec_u && (3'(t) >= start_t) && (u_eff[t] != 2'd0)) begin
        tbl_wr_mask[t] = 1'b1;
        tbl_u_new[t]   = u_eff[t] - 2'd1;
      end
    end

    tbl_wr_mask_o = tbl_wr_mask;
  end

  // ---- Packed 2-Bank 1RW SRAMs (60b = 4 slots x 15b: {uhi[14], ulo[13], tag[12:3], cnt[2:0]}) ----
  logic [59:0] tbl_rd0    [TN];
  logic [59:0] tbl_rd1_nc [TN];
  logic [59:0] tbl_wr_d   [TN];
  logic [59:0] tbl_wr_m   [TN];
  logic        rst_en;
  logic [TN-1:0]         rst_pend_eff, rst_fire, rd0_sup_q;
  logic [IDX_W-1:0]      rst_row_eff;
  logic [FTB_SLOT_W-1:0] rst_sl_eff;
  logic [59:0] rst_wmask;
  logic [5:0]  rst_bit_pos, sl_shift;

  assign reset_cnt_d  = upd_en ? (reset_cnt_q + 32'd1) : reset_cnt_q;
  assign rst_en       = upd_en && (reset_cnt_d[FTB_URST_BITS-1:0] == '0);
  assign rst_pend_eff = rst_en ? {TN{1'b1}} : rst_pend_q;
  assign rst_row_eff  = rst_en ? reset_cnt_d[FTB_URST_BITS +: IDX_W] : rst_row_q;
  assign rst_sl_eff   = rst_en ? upd_sl : rst_sl_q;
  assign rst_bit_pos  = ({4'd0, rst_sl_eff} * 6'd15) + 6'd14;
  assign rst_wmask    = 60'd1 << rst_bit_pos;
  assign sl_shift     = {4'd0, upd_sl} * 6'd15;

  always_comb begin
    for (int t = 0; t < TN; t++) begin
      logic [14:0] lane_d, lane_m;
      rst_fire[t] = rst_pend_eff[t] && !tbl_busy_mask[t][rst_row_eff[BK_W-1:0]];
      lane_d      = 15'd0;
      lane_m      = 15'd0;
      if (tbl_wr_mask[t]) begin
        if (tbl_is_alloc[t]) begin
          lane_d = {tbl_u_new[t], upd_ix.tag[t], tbl_cnt_new[t]};
          lane_m = 15'h7fff;
        end else if (prov_wr_req && (eff_pcpn[1:0] == 2'(t))) begin
          lane_d = {tbl_u_new[t], 10'd0, tbl_cnt_new[t]};
          lane_m = 15'h6007;
        end else begin
          lane_d = {tbl_u_new[t], 13'd0};
          lane_m = 15'h6000;
        end
      end
      tbl_wr_d[t] = {4{lane_d}};
      tbl_wr_m[t] = {45'd0, lane_m} << sl_shift;
    end
  end

  for (genvar t = 0; t < TN; t++) begin : g_tbl
    bpu_sram_1rw_banked #(
      .W       (60),
      .DEPTH   (N_ENT),
      .NB      (NB),
      .MASK_W  (60),
      .HAS_RD1 (1'b0),
      .HAS_RST (1'b1),
      .HOLD_RD0(1'b1),
      .INIT    (60'd0),
      .TAG     (TAG)
    ) u_tbl (
      .clk         (clk),
      .rd0_en      (rd_en && !rd_sup[t]),
      .rd0_addr    (rd_ix.idx[t][IDX_W-1:0]),
      .rd0_data    (tbl_rd0[t]),
      .rd1_en      (1'b0),
      .rd1_addr    ('0),
      .rd1_data    (tbl_rd1_nc[t]),
      .clr_rd_en   (1'b0),
      .clr_rd_addr ('0),
      /* verilator lint_off PINCONNECTEMPTY */
      .clr_rd_data (),
      /* verilator lint_on PINCONNECTEMPTY */
      .wr_en       (tbl_wr_mask[t]),
      .wr_addr     (upd_ix.idx[t][IDX_W-1:0]),
      .wr_data     (tbl_wr_d[t]),
      .wr_wmask    (tbl_wr_m[t]),
      .rst_wr_en   (rst_fire[t]),
      .rst_wr_addr (rst_row_eff),
      .rst_wr_data (60'd0),
      .rst_wr_wmask(rst_wmask)
    );
  end

  always_comb begin
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      rd_raw[sl].base_cnt = 2'd0;
      rd_raw[sl].sup_mask = rd0_sup_q;
      for (int t = 0; t < TN; t++) begin
        logic [14:0] e0;
        e0 = tbl_rd0[t][sl * 15 +: 15];
        if (rd0_sup_q[t]) begin
          rd_raw[sl].cnt[t]    = 3'd0;
          rd_raw[sl].tag[t]    = '0;
          rd_raw[sl].useful[t] = 2'd1;
        end else begin
          rd_raw[sl].cnt[t]    = e0[2:0];
          rd_raw[sl].tag[t]    = e0[12:3];
          rd_raw[sl].useful[t] = e0[14:13];
        end
      end
    end
  end

  // ---- Control state & WRBypass updates ----
  logic [3:0] lsfr_nxt;
  wrb_ent_t   wrb_d [BPU_WRB_N];
  logic [2:0] wrb_ptr_d;

  always_comb begin
    logic hit1, hit2;
    logic [2:0] h1_i, h2_i, p;
    hit1 = 1'b0; h1_i = 3'd0;
    hit2 = 1'b0; h2_i = 3'd0;

    lsfr_nxt    = {lsfr_q[2:0], lsfr_q[3] ^ lsfr_q[2]};
    lsfr_d      = upd_en ? ((lsfr_nxt == 4'd0) ? 4'd1 : lsfr_nxt) : lsfr_q;

    rst_pend_d = rst_pend_eff & ~rst_fire;
    rst_row_d  = rst_row_eff;
    rst_sl_d   = rst_sl_eff;

    use_alt_d = use_alt_q;
    if (upd_en && (eff_pcpn < 3'(TN)) && is_weak && (pdir != eff_alt)) begin
      if (eff_alt == upd_real_dir) begin
        if (use_alt_q > 4'd0)  use_alt_d = use_alt_q - 4'd1;
      end else begin
        if (use_alt_q < 4'd15) use_alt_d = use_alt_q + 4'd1;
      end
    end

    for (int i = 0; i < BPU_WRB_N; i++) wrb_d[i] = wrb_q[i];
    p = wrb_ptr_q;
    if (prov_wr_req) begin
      hit1 = 1'b0; h1_i = 3'd0;
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit1 && wrb_d[i].valid && (wrb_d[i].tbl == eff_pcpn[1:0]) && (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == upd_ix.idx[eff_pcpn[1:0]][IDX_W-1:0])) begin
          hit1 = 1'b1; h1_i = 3'(i);
        end
      if (hit1) begin
        wrb_d[h1_i].cnt = prov_cnt_new;
        wrb_d[h1_i].u   = prov_u_new;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: eff_pcpn[1:0], sl: upd_sl, idx: upd_ix.idx[eff_pcpn[1:0]][IDX_W-1:0], cnt: prov_cnt_new, u: prov_u_new};
        p = p + 3'd1;
      end
    end
    if (do_alloc) begin
      hit2 = 1'b0; h2_i = 3'd0;
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit2 && wrb_d[i].valid && (wrb_d[i].tbl == chosen_t) && (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == upd_ix.idx[chosen_t][IDX_W-1:0])) begin
          hit2 = 1'b1; h2_i = 3'(i);
        end
      if (hit2) begin
        wrb_d[h2_i].cnt = upd_real_dir ? 3'd4 : 3'd3;
        wrb_d[h2_i].u   = 2'd0;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: chosen_t, sl: upd_sl, idx: upd_ix.idx[chosen_t][IDX_W-1:0], cnt: upd_real_dir ? 3'd4 : 3'd3, u: 2'd0};
        p = p + 3'd1;
      end
    end
    wrb_ptr_d = p;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lsfr_q      <= 4'd8;
      reset_cnt_q <= 32'd0;
      use_alt_q   <= FTB_USE_ALT_INIT;
      rst_pend_q  <= '0;
      rst_row_q   <= '0;
      rst_sl_q    <= '0;
      rd0_sup_q   <= '0;
      wrb_ptr_q   <= 3'd0;
      for (int i = 0; i < BPU_WRB_N; i++) wrb_q[i] <= '0;
    end else begin
      lsfr_q      <= lsfr_d;
      reset_cnt_q <= reset_cnt_d;
      use_alt_q   <= use_alt_d;
      rst_pend_q  <= rst_pend_d;
      rst_row_q   <= rst_row_d;
      rst_sl_q    <= rst_sl_d;
      if (rd_en) rd0_sup_q <= rd_sup;
      wrb_ptr_q   <= wrb_ptr_d;
      for (int i = 0; i < BPU_WRB_N; i++) wrb_q[i] <= wrb_d[i];
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{tbl_rd1_nc[0], tbl_rd1_nc[1], tbl_rd1_nc[2], tbl_rd1_nc[3]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
