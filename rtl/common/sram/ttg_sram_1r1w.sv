`default_nettype none
// Ref: (new common primitive) pseudo dual-port synchronous 1R1W SRAM; the model keeps plain arrays
// Pseudo dual-port synchronous 1R1W SRAM primitive (no reset on memory array).
// - INIT_SWEEP=1 (default): while rst_n is low the array is cleared to INIT_VAL through the write port, one
//   address per cycle (docs/modules/common.md 4.1); the reset must last DEPTH + 1 cycles (ttg_rst_sweep).
// - Write-first: a same-cycle R/W to the same address forwards the newly written segments to rdata (every
//   instance needs this; the read-first variant was removed on 2026-11-28).
// - Default (Verilator sim / Yosys SYNTH_MEM=1): clean 1D array inferred as $mem_v2.
// - `ifdef SYNTH_TSMC28_SRAM: real TSMC 28nm HS LVT SRAM macro mapping
//   (small <=1024b arrays -> FFs; larger -> ttg_sram_1rw real macros).
module ttg_sram_1r1w import ttg_sram_pkg::*; #(
  parameter int    DEPTH       = 256,
  parameter int    WIDTH       = 64,
  parameter int    MASK_W      = 1,
  /* verilator lint_off UNUSEDPARAM */
  parameter logic [WIDTH-1:0] INIT_VAL = '0,
  parameter bit    INIT_SWEEP  = 1'b1,
  parameter [255:0] TAG        = "GENERIC"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     re,
  input  logic [$clog2(DEPTH)-1:0] raddr,
  output logic [WIDTH-1:0]         rdata,
  input  logic                     we,
  input  logic [$clog2(DEPTH)-1:0] waddr,
  input  logic [WIDTH-1:0]         wdata,
  input  logic [MASK_W-1:0]        wmask
);

  /* verilator lint_off UNUSEDPARAM */
  localparam int SEG_W = WIDTH / MASK_W;
  /* verilator lint_on UNUSEDPARAM */


  // ---- reset sweep: INIT_VAL -> mem[sw_q] via the write port every reset cycle; sw_q wraps, no reset ----
  localparam int AW = $clog2(DEPTH);
  logic          sweep;
  logic [AW-1:0] sw_q;
  logic          re_i, we_i;
  logic [AW-1:0] raddr_i, waddr_i;
  logic [WIDTH-1:0]  wdata_i;
  logic [MASK_W-1:0] wmask_i;
  assign sweep   = INIT_SWEEP && !rst_n;
  assign re_i    = sweep ? 1'b0 : re;
  assign raddr_i = raddr;
  assign we_i    = sweep ? 1'b1 : we;
  assign waddr_i = sweep ? sw_q : waddr;
  assign wdata_i = sweep ? INIT_VAL : wdata;
  assign wmask_i = sweep ? {MASK_W{1'b1}} : wmask;
  if (INIT_SWEEP) begin : g_sweep
    always_ff @(posedge clk) begin
      if (!rst_n) sw_q <= (sw_q >= AW'(DEPTH - 1)) ? '0 : sw_q + AW'(1);
    end
    if (DEPTH + 1 > SRAM_SWEEP_CYCLES) begin : g_too_deep
      $error("ttg_sram_1r1w %0s: DEPTH %0d needs DEPTH + 1 reset cycles > SRAM_SWEEP_CYCLES %0d",
             TAG, DEPTH, SRAM_SWEEP_CYCLES);
    end
  end else begin : g_no_sweep
    always_ff @(posedge clk) sw_q <= '0;
  end

`ifdef SYNTH_TSMC28_SRAM
  // Real TSMC 28nm HS LVT SRAM macro mapping (ZERO blackbox: real CLK->Q, setup, and macro area).
  // Note: the eda cluster provides prebuilt TSMC28 1RW .lib/.db macros (TEM5N28HPCPLVTA*) without an MC2 license
  // for the 2PRF compiler tarball; functional simulation never defines SYNTH_TSMC28_SRAM.
  if ((DEPTH * WIDTH) <= 1024) begin : g_small_ff
    logic [WIDTH-1:0] mem_q [DEPTH];
    logic [WIDTH-1:0] rdata_q;
    logic             same_addr;
    assign same_addr = re_i && we_i && (raddr_i == waddr_i);
    always_ff @(posedge clk) begin
      if (we_i) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (wmask_i[m]) mem_q[waddr_i][m * SEG_W +: SEG_W] <= wdata_i[m * SEG_W +: SEG_W];
        end
      end
      if (re_i) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (same_addr && wmask_i[m])
            rdata_q[m * SEG_W +: SEG_W] <= wdata_i[m * SEG_W +: SEG_W];
          else
            rdata_q[m * SEG_W +: SEG_W] <= mem_q[raddr_i][m * SEG_W +: SEG_W];
        end
      end
    end
    assign rdata = rdata_q;
  end else begin : g_macro
    localparam int EFF_DEPTH = (DEPTH < 64) ? 64 : DEPTH;
    localparam int EFF_AW    = $clog2(EFF_DEPTH);
    logic [EFF_AW-1:0] raddr_p, waddr_p, m_addr;
    logic [WIDTH-1:0]  m_rdata;
    always_comb begin
      raddr_p = '0;
      waddr_p = '0;
      raddr_p[$clog2(DEPTH)-1:0] = raddr_i;
      waddr_p[$clog2(DEPTH)-1:0] = waddr_i;
      m_addr = we_i ? waddr_p : raddr_p;
    end
    ttg_sram_1rw #(
      .DEPTH   (EFF_DEPTH),
      .WIDTH   (WIDTH),
      .MASK_W  (MASK_W),
      .INIT_VAL(INIT_VAL),
      .INIT_SWEEP(1'b0),
      .TAG     (TAG)
    ) u_macro_1rw (
      .clk  (clk),
      .rst_n(rst_n),
      .en   (re_i || we_i),
      .we   (we_i),
      .addr (m_addr),
      .wdata(wdata_i),
      .wmask(wmask_i),
      .rdata(m_rdata)
    );
    logic              same_q;
    logic [MASK_W-1:0] wmask_q;
    logic [WIDTH-1:0]  wdata_q;
    always_ff @(posedge clk) begin
      same_q <= re_i && we_i && (raddr_i == waddr_i);
      if (re_i && we_i && (raddr_i == waddr_i)) begin
        wmask_q <= wmask_i;
        wdata_q <= wdata_i;
      end
    end
    always_comb begin
      rdata = m_rdata;
      if (same_q) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (wmask_q[m]) rdata[m * SEG_W +: SEG_W] = wdata_q[m * SEG_W +: SEG_W];
        end
      end
    end
  end
`else
  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [WIDTH-1:0] rdata_q;
  logic             same_addr;
  assign same_addr = re_i && we_i && (raddr_i == waddr_i);

  if (MASK_W == 1) begin : g_whole
    always_ff @(posedge clk) begin
      if (we_i && wmask_i[0]) mem_q[waddr_i] <= wdata_i;
      if (re_i) begin
        if (same_addr && wmask_i[0]) rdata_q <= wdata_i;
        else                         rdata_q <= mem_q[raddr_i];
      end
    end
  end else begin : g_masked
    always_ff @(posedge clk) begin
      if (we_i) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (wmask_i[m]) mem_q[waddr_i][m * SEG_W +: SEG_W] <= wdata_i[m * SEG_W +: SEG_W];
        end
      end
      if (re_i) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (same_addr && wmask_i[m])
            rdata_q[m * SEG_W +: SEG_W] <= wdata_i[m * SEG_W +: SEG_W];
          else
            rdata_q[m * SEG_W +: SEG_W] <= mem_q[raddr_i][m * SEG_W +: SEG_W];
        end
      end
    end
  end

  assign rdata = rdata_q;
`endif

endmodule
`default_nettype wire
