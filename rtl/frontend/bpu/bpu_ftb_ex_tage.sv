// Ref: front-end/BPU/BpuSc.h  struct ExBlockTage (v10: Zero-T0-Read Meta + 8-entry FF WRBypass + Deep 1RW)
//   - u_base: 4 banks x (1024 x 8b) 1RW (4 slots x 2b, MASK_W=4, INIT=8'h55)
//   - u_tbl[0..7]: 8 tables x 8 banks x (512 x 64b) 1RW (4 slots x {uhi, ulo, tag[10:0], cnt[2:0]}, MASK_W=64)
//   - Zero T0 read ports! Commit computes write plan from ftb_rec Meta + inline 8-entry FF WRBypass.
//   - Write-wins not-hit on 8-bank tagged tables; Predict-wins on 4-bank base table.
`default_nettype none

module bpu_ftb_ex_tage import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                  clk,
  input  logic                  rst_n,
  // S1 dual sync read launch (per-table sup masks enforce conflict-free 1RW under write-wins)
  input  logic                  rd_en,
  input  logic [EX_TN-1:0]      rd_sup,
  input  logic                  rd2_en,
  input  logic [EX_TN-1:0]      rd2_sup,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_ix_t           rd_ix,
  input  ex_tage_ix_t           rd2_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_tage_raw_t          rd_raw,
  output ex_tage_raw_t          rd2_raw,
  output logic [15:0][3:0]      use_alt_o,
  // Single-cycle pure commit write (computed from ftb_rec Meta + WRBypass; ZERO T0 read!)
  input  logic                  upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_tage_ix_t           upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTB_SLOT_W-1:0] upd_sl,
  input  logic                  upd_real_dir,
  input  logic                  upd_meta_valid,
  input  ex_tage_slot_meta_t    upd_meta,
  input  logic                  do_base_wr,       // gated by Predict-wins on 4-bank u_base
  // Combinational write-bank info exported to bpu_ftb_arrays for write-wins arbitration
  output logic                  base_wr_req_o,
  output logic [EX_TN-1:0]      tbl_wr_mask_o,
  // Per-table 8-bit busy masks (wr | rd0 | rd1) for deferred 1RW uhi periodic reset
  input  logic [EX_TN-1:0][BPU_S2_TAGE_BANKS-1:0] tbl_busy_mask,
  // Exports commit-plan TAGE prediction to S2 SC
  output logic                  upd_pred_o,
  output logic                  upd_prov_hit_o,
  output logic [2:0]            upd_prov_cnt_o,
  output logic [1:0]            upd_base_cnt_o
);

  localparam int IDX_W = $clog2(EX_TAGE_N);

  // ---- Control state registers + per-table deferred 1RW uhi reset ----
  logic [3:0]             lsfr_q, lsfr_d;
  logic [31:0]            reset_cnt_q, reset_cnt_d;
  logic [15:0][3:0]       use_alt_q, use_alt_d;
  logic [EX_TN-1:0]       rst_pend_q, rst_pend_d;
  logic [IDX_W-1:0]       rst_row_q, rst_row_d;
  logic [FTB_SLOT_W-1:0]  rst_sl_q, rst_sl_d;

  assign use_alt_o = use_alt_q;

  // ---- Inline 8-entry FF WRBypass (shared across all 9 combinational lookups: base + pcpn + useful[0..7]) ----
  typedef struct packed {
    logic             valid;
    logic [3:0]       tbl;  // 0..7 tagged, 8 = base
    logic [1:0]       sl;
    logic [IDX_W-1:0] idx;
    logic [2:0]       cnt;
    logic [1:0]       u;
  } wrb_ent_t;

  wrb_ent_t wrb_q [BPU_WRB_N];
  logic [2:0] wrb_ptr_q;

  function automatic logic [5:0] wrb_lookup(input logic [3:0] tbl, input logic [1:0] sl, input logic [IDX_W-1:0] idx);
    // returns {hit, u[1:0], cnt[2:0]}
    for (int i = 0; i < BPU_WRB_N; i++) begin
      if (wrb_q[i].valid && (wrb_q[i].tbl == tbl) && (wrb_q[i].sl == sl) && (wrb_q[i].idx == idx))
        return {1'b1, wrb_q[i].u, wrb_q[i].cnt};
    end
    return 6'd0;
  endfunction

  // ---- Compute pure-combinational commit write plan from Meta + WRBypass ----
  logic [3:0]  eff_pcpn, start_t, nf;
  logic        eff_alt, eff_pred, pdir, is_weak;
  logic [1:0]  bc, nbc, prov_u, prov_u_new;
  logic [2:0]  prov_cnt, prov_cnt_new, free0, free1, chosen_t;
  logic [1:0]  u_eff [EX_TN];
  logic        do_alloc, do_dec_u, base_wr_req, prov_wr_req;
  logic [EX_TN-1:0] tbl_wr_mask, tbl_is_alloc;
  logic [2:0]  tbl_cnt_new [EX_TN];
  logic [1:0]  tbl_u_new   [EX_TN];

  always_comb begin
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] lk_b, lk_p, lk_t;
    /* verilator lint_on UNUSEDSIGNAL */

    eff_pcpn = upd_meta_valid ? upd_meta.pcpn : 4'(EX_TN);
    eff_alt  = upd_meta_valid ? upd_meta.alt  : 1'b0;

    lk_b = wrb_lookup(4'(EX_TN), upd_sl, upd_ix.base_idx);
    bc   = lk_b[5] ? lk_b[1:0] : (upd_meta_valid ? upd_meta.base_cnt : 2'd1);

    lk_p     = (eff_pcpn < 4'(EX_TN)) ? wrb_lookup(eff_pcpn, upd_sl, upd_ix.idx[eff_pcpn[2:0]]) : 6'd0;
    prov_cnt = (eff_pcpn < 4'(EX_TN)) ? (lk_p[5] ? lk_p[2:0] : (upd_meta_valid ? upd_meta.prov_cnt : {1'b0, bc}))
                                      : {1'b0, bc};
    prov_u   = (eff_pcpn < 4'(EX_TN)) ? (lk_p[5] ? lk_p[4:3] : (upd_meta_valid ? upd_meta.prov_u : 2'd0))
                                      : 2'd0;

    eff_pred       = upd_meta_valid ? upd_meta.pred : (bc >= 2'd2);
    upd_pred_o     = eff_pred;
    upd_prov_hit_o = (eff_pcpn < 4'(EX_TN));
    upd_prov_cnt_o = (eff_pcpn == 4'(EX_TN)) ? {1'b0, bc} : prov_cnt;
    upd_base_cnt_o = bc;

    nbc         = upd_real_dir ? ((bc < 2'd3) ? (bc + 2'd1) : 2'd3)
                               : ((bc > 2'd0) ? (bc - 2'd1) : 2'd0);
    base_wr_req = upd_en && (eff_pcpn == 4'(EX_TN)) && (nbc != bc);

    pdir         = (prov_cnt >= 3'd4);
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
    nf      = 4'd0;
    free0   = 3'd0;
    free1   = 3'd0;
    for (int t = 0; t < EX_TN; t++) begin
      lk_t     = wrb_lookup(4'(t), upd_sl, upd_ix.idx[t]);
      u_eff[t] = lk_t[5] ? lk_t[4:3] : (upd_meta_valid ? upd_meta.useful[t] : 2'd0);
      if ((4'(t) >= start_t) && (u_eff[t] == 2'd0)) begin
        if (nf == 4'd0) free0 = 3'(t);
        if (nf == 4'd1) free1 = 3'(t);
        nf = nf + 4'd1;
      end
    end
    chosen_t = ((nf > 4'd1) && (lsfr_q[1:0] == 2'b00)) ? free1 : free0;
    do_alloc = upd_en && (!upd_meta_valid || (eff_pred != upd_real_dir)) && (nf != 4'd0);
    do_dec_u = upd_en && (!upd_meta_valid || (eff_pred != upd_real_dir)) && (nf == 4'd0);

    tbl_wr_mask  = '0;
    tbl_is_alloc = '0;
    for (int t = 0; t < EX_TN; t++) begin
      tbl_cnt_new[t] = 3'd0;
      tbl_u_new[t]   = 2'd0;
      if (prov_wr_req && (eff_pcpn[2:0] == 3'(t))) begin
        tbl_wr_mask[t] = 1'b1;
        tbl_cnt_new[t] = prov_cnt_new;
        tbl_u_new[t]   = prov_u_new;
      end else if (do_alloc && (chosen_t == 3'(t))) begin
        tbl_wr_mask[t]  = 1'b1;
        tbl_is_alloc[t] = 1'b1;
        tbl_cnt_new[t]  = upd_real_dir ? 3'd4 : 3'd3;
        tbl_u_new[t]    = 2'd0;
      end else if (do_dec_u && (4'(t) >= start_t) && (u_eff[t] != 2'd0)) begin
        tbl_wr_mask[t] = 1'b1;
        tbl_u_new[t]   = u_eff[t] - 2'd1;
      end
    end

    base_wr_req_o = base_wr_req;
    tbl_wr_mask_o = tbl_wr_mask;
  end

  // ---- Packed 4-Bank u_base + 8-Bank u_tbl[0..7] 1RW SRAMs (ZERO T0 read ports!) ----
  logic [7:0] base_rd0, base_rd1, base_wr_d;
  logic [3:0] base_wr_m;

  assign base_wr_d = {4{nbc}};
  assign base_wr_m = 4'd1 << upd_sl;

  bpu_sram_1rw_banked #(
    .W      (8),
    .DEPTH  (EX_TAGE_N),
    .NB     (BPU_FTB1_BANKS),
    .MASK_W (4),
    .HAS_RD1(1'b1),
    .HAS_RST(1'b0),
    .INIT   (8'h55),
    .TAG    ("BPU_S2_TAGE_BASE")
  ) u_base (
    .clk         (clk),
    .rd0_en      (rd_en),
    .rd0_addr    (rd_ix.base_idx),
    .rd0_data    (base_rd0),
    .rd1_en      (rd2_en),
    .rd1_addr    (rd2_ix.base_idx),
    .rd1_data    (base_rd1),
    .clr_rd_en   (1'b0),
    .clr_rd_addr ('0),
    /* verilator lint_off PINCONNECTEMPTY */
    .clr_rd_data (),
    /* verilator lint_on PINCONNECTEMPTY */
    .wr_en       (base_wr_req && do_base_wr),
    .wr_addr     (upd_ix.base_idx),
    .wr_data     (base_wr_d),
    .wr_wmask    (base_wr_m),
    .rst_wr_en   (1'b0),
    .rst_wr_addr ('0),
    .rst_wr_data ('0),
    .rst_wr_wmask('0)
  );

  logic [63:0] tbl_rd0   [EX_TN];
  logic [63:0] tbl_rd1   [EX_TN];
  logic [63:0] tbl_wr_d  [EX_TN];
  logic [63:0] tbl_wr_m  [EX_TN];
  logic        rst_en;
  logic [EX_TN-1:0]      rst_pend_eff, rst_fire;
  logic [IDX_W-1:0]      rst_row_eff;
  logic [FTB_SLOT_W-1:0] rst_sl_eff;
  logic [63:0] rst_wmask;
  logic [EX_TN-1:0] rd0_sup_q, rd1_sup_q;

  assign reset_cnt_d  = upd_en ? (reset_cnt_q + 32'd1) : reset_cnt_q;
  assign rst_en       = upd_en && (reset_cnt_d[EX_TAGE_URST-1:0] == '0);
  assign rst_pend_eff = rst_en ? {EX_TN{1'b1}} : rst_pend_q;
  assign rst_row_eff  = rst_en ? reset_cnt_d[EX_TAGE_URST +: IDX_W] : rst_row_q;
  assign rst_sl_eff   = rst_en ? upd_sl : rst_sl_q;
  assign rst_wmask    = 64'd1 << {rst_sl_eff, 4'd15};

  always_comb begin
    for (int t = 0; t < EX_TN; t++) begin
      logic [15:0] lane_d, lane_m;
      rst_fire[t] = rst_pend_eff[t] && !tbl_busy_mask[t][rst_row_eff[2:0]];
      lane_d      = 16'd0;
      lane_m      = 16'd0;
      if (tbl_wr_mask[t]) begin
        if (tbl_is_alloc[t]) begin
          lane_d = {tbl_u_new[t], upd_ix.tag[t], tbl_cnt_new[t]};
          lane_m = 16'hffff;
        end else if (prov_wr_req && (eff_pcpn[2:0] == 3'(t))) begin
          // Update u & cnt via bit-level wmask (preserves tag without T0 read!)
          lane_d = {tbl_u_new[t], 11'd0, tbl_cnt_new[t]};
          lane_m = 16'hc007;
        end else begin
          // u-only decrement via bit-level wmask (preserves tag & cnt without T0 read!)
          lane_d = {tbl_u_new[t], 14'd0};
          lane_m = 16'hc000;
        end
      end
      tbl_wr_d[t] = {4{lane_d}};
      tbl_wr_m[t] = {48'd0, lane_m} << {upd_sl, 4'd0};
    end
  end

  for (genvar t = 0; t < EX_TN; t++) begin : g_tbl
    bpu_sram_1rw_banked #(
      .W      (64),
      .DEPTH  (EX_TAGE_N),
      .NB     (BPU_S2_TAGE_BANKS),
      .MASK_W (64),
      .HAS_RD1(1'b1),
      .HAS_RST(1'b1),
      .INIT   (64'd0),
      .TAG    ("BPU_S2_TAGE_TBL")
    ) u_tbl (
      .clk         (clk),
      .rd0_en      (rd_en && !rd_sup[t]),
      .rd0_addr    (rd_ix.idx[t]),
      .rd0_data    (tbl_rd0[t]),
      .rd1_en      (rd2_en && !rd2_sup[t]),
      .rd1_addr    (rd2_ix.idx[t]),
      .rd1_data    (tbl_rd1[t]),
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
      .rst_wr_data (64'd0),
      .rst_wr_wmask(rst_wmask)
    );
  end

  // ---- Unpack predict raw (suppressed 1RW banks force tag=0, cnt=0, useful=1, matching BpuSc.h!) ----
  always_comb begin
    for (int sl = 0; sl < FTB_SLOTS; sl++) begin
      rd_raw[sl].base_cnt  = base_rd0[sl * 2 +: 2];
      rd_raw[sl].sup_mask  = rd0_sup_q;
      rd2_raw[sl].base_cnt = base_rd1[sl * 2 +: 2];
      rd2_raw[sl].sup_mask = rd1_sup_q;
      for (int t = 0; t < EX_TN; t++) begin
        logic [15:0] e0, e1;
        e0 = tbl_rd0[t][sl * 16 +: 16];
        e1 = tbl_rd1[t][sl * 16 +: 16];
        if (rd0_sup_q[t]) begin
          rd_raw[sl].cnt[t]    = 3'd0;
          rd_raw[sl].tag[t]    = '0;
          rd_raw[sl].useful[t] = 2'd1;
        end else begin
          rd_raw[sl].cnt[t]    = e0[2:0];
          rd_raw[sl].tag[t]    = e0[13:3];
          rd_raw[sl].useful[t] = e0[15:14];
        end
        if (rd1_sup_q[t]) begin
          rd2_raw[sl].cnt[t]    = 3'd0;
          rd2_raw[sl].tag[t]    = '0;
          rd2_raw[sl].useful[t] = 2'd1;
        end else begin
          rd2_raw[sl].cnt[t]    = e1[2:0];
          rd2_raw[sl].tag[t]    = e1[13:3];
          rd2_raw[sl].useful[t] = e1[15:14];
        end
      end
    end
  end

  // ---- Control state & WRBypass updates ----
  logic [3:0] lsfr_nxt, ua_idx, ua_cur;

  always_comb begin
    lsfr_nxt    = {lsfr_q[2:0], lsfr_q[3] ^ lsfr_q[2]};
    lsfr_d      = upd_en ? ((lsfr_nxt == 4'd0) ? 4'd1 : lsfr_nxt) : lsfr_q;

    rst_pend_d = rst_pend_eff & ~rst_fire;
    rst_row_d  = rst_row_eff;
    rst_sl_d   = rst_sl_eff;

    ua_idx    = upd_ix.w[5:2];
    ua_cur    = use_alt_q[ua_idx];
    use_alt_d = use_alt_q;
    if (upd_en && (eff_pcpn < 4'(EX_TN)) && is_weak && (pdir != eff_alt)) begin
      if (eff_alt == upd_real_dir) begin
        if (ua_cur > 4'd0)  use_alt_d[ua_idx] = ua_cur - 4'd1;
      end else begin
        if (ua_cur < 4'd15) use_alt_d[ua_idx] = ua_cur + 4'd1;
      end
    end
  end

  // Helper task for WRBypass sequential insert (up to 2 inserts per cycle: base/prov + alloc)
  wrb_ent_t wrb_d [BPU_WRB_N];
  logic [2:0] wrb_ptr_d;

  always_comb begin
    logic hit1, hit2;
    logic [2:0] h1_i, h2_i, p;
    hit1 = 1'b0; h1_i = 3'd0;
    hit2 = 1'b0; h2_i = 3'd0;
    for (int i = 0; i < BPU_WRB_N; i++) wrb_d[i] = wrb_q[i];
    p = wrb_ptr_q;

    // Insert 1: base_wr (if fired) or prov_wr
    if (base_wr_req && do_base_wr) begin
      hit1 = 1'b0; h1_i = 3'd0;
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit1 && wrb_d[i].valid && (wrb_d[i].tbl == 4'(EX_TN)) && (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == upd_ix.base_idx)) begin
          hit1 = 1'b1; h1_i = 3'(i);
        end
      if (hit1) begin
        wrb_d[h1_i].cnt = {1'b0, nbc};
        wrb_d[h1_i].u   = 2'd0;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: 4'(EX_TN), sl: upd_sl, idx: upd_ix.base_idx, cnt: {1'b0, nbc}, u: 2'd0};
        p = p + 3'd1;
      end
    end else if (prov_wr_req) begin
      hit1 = 1'b0; h1_i = 3'd0;
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit1 && wrb_d[i].valid && (wrb_d[i].tbl == eff_pcpn) && (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == upd_ix.idx[eff_pcpn[2:0]])) begin
          hit1 = 1'b1; h1_i = 3'(i);
        end
      if (hit1) begin
        wrb_d[h1_i].cnt = prov_cnt_new;
        wrb_d[h1_i].u   = prov_u_new;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: eff_pcpn, sl: upd_sl, idx: upd_ix.idx[eff_pcpn[2:0]], cnt: prov_cnt_new, u: prov_u_new};
        p = p + 3'd1;
      end
    end

    // Insert 2: alloc (chosen_t)
    if (do_alloc) begin
      hit2 = 1'b0; h2_i = 3'd0;
      for (int i = 0; i < BPU_WRB_N; i++)
        if (!hit2 && wrb_d[i].valid && (wrb_d[i].tbl == {1'b0, chosen_t}) && (wrb_d[i].sl == upd_sl) && (wrb_d[i].idx == upd_ix.idx[chosen_t])) begin
          hit2 = 1'b1; h2_i = 3'(i);
        end
      if (hit2) begin
        wrb_d[h2_i].cnt = upd_real_dir ? 3'd4 : 3'd3;
        wrb_d[h2_i].u   = 2'd0;
      end else begin
        wrb_d[p] = '{valid: 1'b1, tbl: {1'b0, chosen_t}, sl: upd_sl, idx: upd_ix.idx[chosen_t], cnt: upd_real_dir ? 3'd4 : 3'd3, u: 2'd0};
        p = p + 3'd1;
      end
    end
    wrb_ptr_d = p;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lsfr_q      <= 4'd8;
      reset_cnt_q <= 32'd0;
      rst_pend_q  <= '0;
      rst_row_q   <= '0;
      rst_sl_q    <= '0;
      rd0_sup_q   <= '0;
      rd1_sup_q   <= '0;
      wrb_ptr_q   <= 3'd0;
      for (int i = 0; i < 16; i++) use_alt_q[i] <= FTB_USE_ALT_INIT;
      for (int i = 0; i < BPU_WRB_N; i++) wrb_q[i] <= '0;
    end else begin
      lsfr_q      <= lsfr_d;
      reset_cnt_q <= reset_cnt_d;
      rst_pend_q  <= rst_pend_d;
      rst_row_q   <= rst_row_d;
      rst_sl_q    <= rst_sl_d;
      rd0_sup_q   <= rd_sup;
      rd1_sup_q   <= rd2_sup;
      wrb_ptr_q   <= wrb_ptr_d;
      use_alt_q   <= use_alt_d;
      for (int i = 0; i < BPU_WRB_N; i++) wrb_q[i] <= wrb_d[i];
    end
  end

endmodule

`default_nettype wire
