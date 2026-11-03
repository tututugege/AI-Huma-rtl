// Ref: front-end/BPU/dir_predictor/TAGE_top.h  class TAGE_TOP (one bank)
`default_nettype none

// One TAGE bank: base counters, 4 tagged tables (tag/cnt/useful) and the state registers LSFR, reset counter and
// use-alt counter.  Prediction and update may share a cycle; both read the START-of-cycle arrays.
module bpu_tage_bank import bpu_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [FH_W-1:0]     fh          [FH_K][TN],
  input  logic [T_BASE_W-1:0] pred_pc_idx,
  input  logic                update_en,
  input  logic [T_BASE_W-1:0] upd_pc_idx,
  input  logic                real_dir,
  input  logic                pred_in,
  input  logic                alt_pred_in,
  input  logic [PCPN_W-1:0]   pcpn_in,
  input  logic [T_TAG_W-1:0]  tag_in      [TN],
  input  logic [T_IDX_W-1:0]  idx_in      [TN],
  output logic                pred_out,
  output logic                alt_pred_out,
  output logic [PCPN_W-1:0]   pcpn_out,
  output logic [PCPN_W-1:0]   altpcpn_out,
  output logic [T_TAG_W-1:0]  tag_out     [TN],
  output logic [T_IDX_W-1:0]  idx_out     [TN]
);

  localparam int DEPTH = 1 << T_IDX_W;

  // state registers (reset values: TAGE_TOP::reset)
  logic [3:0]  lsfr_q;            // LSFR[3..0] = 4'b1000
  logic [3:0]  lsfr_d;
  logic [23:0] reset_cnt_q;       // only bits 0..23 of the C++ 32-bit counter are ever read
  logic [23:0] reset_cnt_d;
  logic [3:0]  use_alt_q;         // TAGE_USE_ALT_CTR_INIT = 7
  logic [3:0]  use_alt_d;

  // array reads: prediction at idx_out, update at idx_in (+ the useful row being cleared)
  logic [1:0]          base_rd   [2];
  logic [T_BASE_W-1:0] base_addr [2];
  logic [T_TAG_W-1:0]  pred_tag  [TN];
  logic [2:0]          pred_cnt  [TN];
  logic [1:0]          pred_useful [TN];
  logic [2:0]          upd_cnt   [TN];
  logic [1:0]          upd_useful [TN];
  logic [1:0]          row_useful [TN];
  // update decisions
  logic                base_we;
  logic [1:0]          base_wdata;
  logic                cnt_we     [TN];
  logic [2:0]          cnt_wdata  [TN];
  logic                useful_we  [TN];
  logic [1:0]          useful_wdata [TN];
  logic                tag_we     [TN];
  logic                reset_we   [TN];
  logic [T_IDX_W-1:0]  reset_row;
  logic [1:0]          reset_wdata [TN];
  logic                use_alt_we;
  logic [3:0]          use_alt_wdata;
  logic [3:0]          lsfr_next;
  logic [23:0]         reset_cnt_next;
  logic [1:0]          pred_base_cnt;
  logic [1:0]          upd_base_cnt;

  bpu_tage_pred u_pred (
    .pc_idx(pred_pc_idx), .fh(fh), .base_cnt(pred_base_cnt), .rd_tag(pred_tag), .rd_cnt(pred_cnt),
    .rd_useful(pred_useful), .use_alt_ctr(use_alt_q), .idx(idx_out), .tag(tag_out), .pred(pred_out),
    .alt_pred(alt_pred_out), .pcpn(pcpn_out), .altpcpn(altpcpn_out)
  );

  bpu_tage_upd u_upd (
    .idx_in(idx_in), .real_dir(real_dir), .pred_in(pred_in), .alt_pred_in(alt_pred_in), .pcpn_in(pcpn_in),
    .base_cnt(upd_base_cnt), .rd_cnt(upd_cnt), .rd_useful(upd_useful), .reset_row_useful(row_useful),
    .lsfr(lsfr_q), .reset_cnt(reset_cnt_q), .use_alt_ctr(use_alt_q),
    .base_we(base_we), .base_wdata(base_wdata), .cnt_we(cnt_we), .cnt_wdata(cnt_wdata), .useful_we(useful_we),
    .useful_wdata(useful_wdata), .tag_we(tag_we), .reset_we(reset_we), .reset_row(reset_row),
    .reset_wdata(reset_wdata), .use_alt_we(use_alt_we), .use_alt_wdata(use_alt_wdata), .lsfr_next(lsfr_next),
    .reset_cnt_next(reset_cnt_next)
  );

  // ---- base counters ----
  if (1) begin : g_base
    logic       wr_en   [1];
    logic [T_BASE_W-1:0] wr_addr [1];
    logic [1:0] wr_data [1];
    always_comb begin
      base_addr[0] = pred_pc_idx;
      base_addr[1] = upd_pc_idx;
      wr_en[0]     = update_en && base_we;
      wr_addr[0]   = upd_pc_idx;
      wr_data[0]   = base_wdata;
    end
    bpu_mem #(.W(2), .DEPTH(DEPTH), .N_RD(2), .N_WR(1)) u_mem (
      .clk(clk), .rst_n(rst_n), .rd_addr(base_addr), .rd_data(base_rd),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    assign pred_base_cnt = base_rd[0];
    assign upd_base_cnt  = base_rd[1];
  end

  // ---- tagged tables ----
  for (genvar i = 0; i < TN; i++) begin : g_tbl
    logic [T_IDX_W-1:0] tag_rd_addr [1];
    logic [T_TAG_W-1:0] tag_rd_data [1];
    logic               tag_wr_en   [1];
    logic [T_IDX_W-1:0] tag_wr_addr [1];
    logic [T_TAG_W-1:0] tag_wr_data [1];
    logic [T_IDX_W-1:0] cnt_rd_addr [2];
    logic [2:0]         cnt_rd_data [2];
    logic               cnt_wr_en   [1];
    logic [T_IDX_W-1:0] cnt_wr_addr [1];
    logic [2:0]         cnt_wr_data [1];
    logic [T_IDX_W-1:0] use_rd_addr [3];
    logic [1:0]         use_rd_data [3];
    logic               use_wr_en   [2];
    logic [T_IDX_W-1:0] use_wr_addr [2];
    logic [1:0]         use_wr_data [2];
    always_comb begin
      tag_rd_addr[0] = idx_out[i];
      tag_wr_en[0]   = update_en && tag_we[i];
      tag_wr_addr[0] = idx_in[i];
      tag_wr_data[0] = tag_in[i];
      cnt_rd_addr[0] = idx_out[i];
      cnt_rd_addr[1] = idx_in[i];
      cnt_wr_en[0]   = update_en && cnt_we[i];
      cnt_wr_addr[0] = idx_in[i];
      cnt_wr_data[0] = cnt_wdata[i];
      use_rd_addr[0] = idx_out[i];
      use_rd_addr[1] = idx_in[i];
      use_rd_addr[2] = reset_row;
      use_wr_en[0]   = update_en && useful_we[i];
      use_wr_addr[0] = idx_in[i];
      use_wr_data[0] = useful_wdata[i];
      use_wr_en[1]   = update_en && reset_we[i];
      use_wr_addr[1] = reset_row;
      use_wr_data[1] = reset_wdata[i];
    end
    bpu_mem #(.W(T_TAG_W), .DEPTH(DEPTH), .N_RD(1), .N_WR(1)) u_tag (
      .clk(clk), .rst_n(rst_n), .rd_addr(tag_rd_addr), .rd_data(tag_rd_data),
      .wr_en(tag_wr_en), .wr_addr(tag_wr_addr), .wr_data(tag_wr_data)
    );
    bpu_mem #(.W(3), .DEPTH(DEPTH), .N_RD(2), .N_WR(1)) u_cnt (
      .clk(clk), .rst_n(rst_n), .rd_addr(cnt_rd_addr), .rd_data(cnt_rd_data),
      .wr_en(cnt_wr_en), .wr_addr(cnt_wr_addr), .wr_data(cnt_wr_data)
    );
    bpu_mem #(.W(2), .DEPTH(DEPTH), .N_RD(3), .N_WR(2)) u_useful (
      .clk(clk), .rst_n(rst_n), .rd_addr(use_rd_addr), .rd_data(use_rd_data),
      .wr_en(use_wr_en), .wr_addr(use_wr_addr), .wr_data(use_wr_data)
    );
    assign pred_tag[i]    = tag_rd_data[0];
    assign pred_cnt[i]    = cnt_rd_data[0];
    assign upd_cnt[i]     = cnt_rd_data[1];
    assign pred_useful[i] = use_rd_data[0];
    assign upd_useful[i]  = use_rd_data[1];
    assign row_useful[i]  = use_rd_data[2];
  end

  // ---- state registers ----
  always_comb begin
    lsfr_d      = update_en ? lsfr_next : lsfr_q;
    reset_cnt_d = update_en ? reset_cnt_next : reset_cnt_q;
    use_alt_d   = (update_en && use_alt_we) ? use_alt_wdata : use_alt_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lsfr_q      <= 4'b1000;
      reset_cnt_q <= '0;
      use_alt_q   <= 4'd7;
    end else begin
      lsfr_q      <= lsfr_d;
      reset_cnt_q <= reset_cnt_d;
      use_alt_q   <= use_alt_d;
    end
  end

endmodule

`default_nettype wire
