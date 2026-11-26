// Ref: front-end/BPU/BpuSc.h & BPU_pipe.h
// Multi-bank single-port 1RW synchronous SRAM wrapper for BPU arrays (v10: ZERO N_RD replication, ZERO T0 read port).
// Instantiates NB independent `ttg_sram_1rw` banks of depth (DEPTH / NB) and width W with MASK_W write mask.
// Bank selection uses the lowest $clog2(NB) address bits; the caller guarantees <= 1 active op per bank per cycle
// (enforced by a simulation-only assertion).
`default_nettype none

module bpu_sram_1rw_banked #(
  parameter int    W           = 64,
  parameter int    DEPTH       = 4096,
  parameter int    NB          = 8,
  parameter int    MASK_W      = 1,
  parameter bit    HAS_RD1     = 1'b1,
  parameter bit    HAS_RST     = 1'b0,
  parameter bit    HAS_CLR_RD  = 1'b0,
  parameter bit    HOLD_RD0    = 1'b0,
  parameter logic [W-1:0] INIT = '0,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG        = "BPU_1RW"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                     clk,
  // Predict read port 0 (Block A / Ahead predict)
  input  logic                     rd0_en,
  input  logic [$clog2(DEPTH)-1:0] rd0_addr,
  output logic [W-1:0]             rd0_data,
  // Optional predict read port 1 (Block B, when HAS_RD1=1)
  input  logic                     rd1_en,
  input  logic [$clog2(DEPTH)-1:0] rd1_addr,
  output logic [W-1:0]             rd1_data,
  // Optional rare predecode false-branch clear read port (ONLY on u_ftb1 when HAS_CLR_RD=1)
  input  logic                     clr_rd_en,
  input  logic [$clog2(DEPTH)-1:0] clr_rd_addr,
  output logic [W-1:0]             clr_rd_data,
  // Commit write port (single-cycle pure write; ZERO T0 read!)
  input  logic                     wr_en,
  input  logic [$clog2(DEPTH)-1:0] wr_addr,
  input  logic [W-1:0]             wr_data,
  input  logic [MASK_W-1:0]        wr_wmask,
  // Optional deferred periodic uhi reset write port (when HAS_RST=1)
  input  logic                     rst_wr_en,
  input  logic [$clog2(DEPTH)-1:0] rst_wr_addr,
  input  logic [W-1:0]             rst_wr_data,
  input  logic [MASK_W-1:0]        rst_wr_wmask
);

  localparam int ADDR_W   = $clog2(DEPTH);
  localparam int BK_W     = (NB > 1) ? $clog2(NB) : 1;
  localparam int BK_DEPTH = DEPTH / NB;
  localparam int ROW_W    = (BK_DEPTH > 1) ? $clog2(BK_DEPTH) : 1;

  logic [BK_W-1:0]  rd0_bk, rd1_bk, clr_bk, wr_bk, rst_bk;
  logic [ROW_W-1:0] rd0_row, rd1_row, clr_row, wr_row, rst_row;
  logic [BK_W-1:0]  rd0_bk_q, rd1_bk_q, clr_bk_q;

  generate
    if (NB > 1) begin : g_split_nb
      assign rd0_bk  = rd0_addr[BK_W-1:0];
      assign rd1_bk  = rd1_addr[BK_W-1:0];
      assign clr_bk  = clr_rd_addr[BK_W-1:0];
      assign wr_bk   = wr_addr[BK_W-1:0];
      assign rst_bk  = rst_wr_addr[BK_W-1:0];
      assign rd0_row = rd0_addr[ADDR_W-1:BK_W];
      assign rd1_row = rd1_addr[ADDR_W-1:BK_W];
      assign clr_row = clr_rd_addr[ADDR_W-1:BK_W];
      assign wr_row  = wr_addr[ADDR_W-1:BK_W];
      assign rst_row = rst_wr_addr[ADDR_W-1:BK_W];
    end else begin : g_split_1
      assign rd0_bk  = 1'b0;
      assign rd1_bk  = 1'b0;
      assign clr_bk  = 1'b0;
      assign wr_bk   = 1'b0;
      assign rst_bk  = 1'b0;
      assign rd0_row = rd0_addr;
      assign rd1_row = rd1_addr;
      assign clr_row = clr_rd_addr;
      assign wr_row  = wr_addr;
      assign rst_row = rst_wr_addr;
    end
  endgenerate

  logic              bk_en    [NB];
  logic              bk_we    [NB];
  logic [ROW_W-1:0]  bk_addr  [NB];
  logic [W-1:0]      bk_wdata [NB];
  logic [MASK_W-1:0] bk_wmask [NB];
  logic [W-1:0]      bk_rdata [NB];

  always_comb begin
    for (int b = 0; b < NB; b++) begin
      logic h_rd0, h_rd1, h_clr, h_wr, h_rst;
      h_rd0 = rd0_en && (rd0_bk == BK_W'(b));
      h_rd1 = HAS_RD1 && rd1_en && (rd1_bk == BK_W'(b));
      h_clr = HAS_CLR_RD && clr_rd_en && (clr_bk == BK_W'(b));
      h_wr  = wr_en && (wr_bk == BK_W'(b));
      h_rst = HAS_RST && rst_wr_en && (rst_bk == BK_W'(b));

      bk_en[b]    = h_rd0 || h_rd1 || h_clr || h_wr || h_rst;
      bk_we[b]    = 1'b0;
      bk_addr[b]  = rd0_row;
      bk_wdata[b] = wr_data;
      bk_wmask[b] = wr_wmask;

      if (h_wr) begin
        bk_we[b]    = 1'b1;
        bk_addr[b]  = wr_row;
        bk_wdata[b] = wr_data;
        bk_wmask[b] = wr_wmask;
      end else if (h_rd0) begin
        bk_we[b]   = 1'b0;
        bk_addr[b] = rd0_row;
      end else if (h_rd1) begin
        bk_we[b]   = 1'b0;
        bk_addr[b] = rd1_row;
      end else if (h_clr) begin
        bk_we[b]   = 1'b0;
        bk_addr[b] = clr_row;
      end else if (h_rst) begin
        bk_we[b]    = 1'b1;
        bk_addr[b]  = rst_row;
        bk_wdata[b] = rst_wr_data;
        bk_wmask[b] = rst_wr_wmask;
      end
    end
  end

  for (genvar b = 0; b < NB; b++) begin : g_bk
    ttg_sram_1rw #(
      .DEPTH   (BK_DEPTH),
      .WIDTH   (W),
      .MASK_W  (MASK_W),
      .INIT_VAL(INIT),
      .TAG     (TAG)
    ) u_sram (
      .clk  (clk),
      .en   (bk_en[b]),
      .we   (bk_we[b]),
      .addr (bk_addr[b]),
      .wdata(bk_wdata[b]),
      .wmask(bk_wmask[b]),
      .rdata(bk_rdata[b])
    );
  end

  always_ff @(posedge clk) begin
    if (rd0_en) rd0_bk_q <= rd0_bk;
    if (HAS_RD1 && rd1_en) rd1_bk_q <= rd1_bk;
    if (HAS_CLR_RD && clr_rd_en) clr_bk_q <= clr_bk;
  end

  if (HOLD_RD0) begin : g_hold_rd0
    logic         rd0_en_q;
    logic [W-1:0] rd0_hold_q;
    always_ff @(posedge clk) begin
      rd0_en_q <= rd0_en;
      if (rd0_en_q) rd0_hold_q <= bk_rdata[rd0_bk_q];
    end
    assign rd0_data = rd0_en_q ? bk_rdata[rd0_bk_q] : rd0_hold_q;
  end else begin : g_no_hold_rd0
    assign rd0_data = bk_rdata[rd0_bk_q];
  end

  assign rd1_data    = HAS_RD1    ? bk_rdata[rd1_bk_q] : '0;
  assign clr_rd_data = HAS_CLR_RD ? bk_rdata[clr_bk_q] : '0;

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    for (int b = 0; b < NB; b++) begin
      int nops;
      nops = int'(rd0_en && (rd0_bk == BK_W'(b))) +
             int'(HAS_RD1 && rd1_en && (rd1_bk == BK_W'(b))) +
             int'(HAS_CLR_RD && clr_rd_en && (clr_bk == BK_W'(b))) +
             int'(wr_en && (wr_bk == BK_W'(b))) +
             int'(HAS_RST && rst_wr_en && (rst_bk == BK_W'(b)));
      if (nops > 1)
        $error("bpu_sram_1rw_banked(%s): bank %0d conflict (%0d ops: rd0=%0b rd1=%0b clr=%0b wr=%0b rst=%0b)",
               TAG, b, nops,
               rd0_en && (rd0_bk == BK_W'(b)),
               HAS_RD1 && rd1_en && (rd1_bk == BK_W'(b)),
               HAS_CLR_RD && clr_rd_en && (clr_bk == BK_W'(b)),
               wr_en && (wr_bk == BK_W'(b)),
               HAS_RST && rst_wr_en && (rst_bk == BK_W'(b)));
    end
  end
`endif

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{rd1_en, rd1_addr, rd1_bk_q, clr_rd_en, clr_rd_addr, clr_bk_q,
                       rst_wr_en, rst_wr_addr, rst_wr_data, rst_wr_wmask};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
