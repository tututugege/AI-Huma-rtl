`default_nettype none
// Pseudo dual-port synchronous 1R1W SRAM primitive (no reset on memory array).
// - WRITE_FIRST=0: standard 1R1W SRAM (same-cycle R/W to same address returns pre-write data).
// - WRITE_FIRST=1: same-cycle R/W to same address forwards newly written segments to rdata.
// - Default (Verilator sim / Yosys SYNTH_MEM=1): clean 1D array inferred as $mem_v2.
// - `ifdef SYNTH_TSMC28_SRAM: real TSMC 28nm HS LVT SRAM macro mapping (small <=1024b arrays -> FFs; larger -> ttg_sram_1rw real macros).
module ttg_sram_1r1w #(
  parameter int    DEPTH       = 256,
  parameter int    WIDTH       = 64,
  parameter int    MASK_W      = 1,
  /* verilator lint_off UNUSEDPARAM */
  parameter bit    WRITE_FIRST = 1'b0,
  parameter logic [WIDTH-1:0] INIT_VAL = '0,
  parameter [255:0] TAG        = "GENERIC"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                     clk,
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

`ifdef SYNTH_TSMC28_SRAM
  // Real TSMC 28nm HS LVT SRAM macro mapping (ZERO blackbox: real CLK->Q, setup, and macro area).
  // Note: the eda cluster provides prebuilt TSMC28 1RW .lib/.db macros (TEM5N28HPCPLVTA*) without an MC2 license
  // for the 2PRF compiler tarball; functional simulation never defines SYNTH_TSMC28_SRAM.
  if ((DEPTH * WIDTH) <= 1024) begin : g_small_ff
    logic [WIDTH-1:0] mem_q [DEPTH];
    logic [WIDTH-1:0] rdata_q;
    logic             same_addr;
    assign same_addr = re && we && (raddr == waddr);
    always_ff @(posedge clk) begin
      if (we) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (wmask[m]) mem_q[waddr][m * SEG_W +: SEG_W] <= wdata[m * SEG_W +: SEG_W];
        end
      end
      if (re) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (WRITE_FIRST && same_addr && wmask[m])
            rdata_q[m * SEG_W +: SEG_W] <= wdata[m * SEG_W +: SEG_W];
          else
            rdata_q[m * SEG_W +: SEG_W] <= mem_q[raddr][m * SEG_W +: SEG_W];
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
      raddr_p[$clog2(DEPTH)-1:0] = raddr;
      waddr_p[$clog2(DEPTH)-1:0] = waddr;
      m_addr = we ? waddr_p : raddr_p;
    end
    ttg_sram_1rw #(
      .DEPTH   (EFF_DEPTH),
      .WIDTH   (WIDTH),
      .MASK_W  (MASK_W),
      .INIT_VAL(INIT_VAL),
      .TAG     (TAG)
    ) u_macro_1rw (
      .clk  (clk),
      .en   (re || we),
      .we   (we),
      .addr (m_addr),
      .wdata(wdata),
      .wmask(wmask),
      .rdata(m_rdata)
    );
    if (WRITE_FIRST) begin : g_wf
      logic              same_q;
      logic [MASK_W-1:0] wmask_q;
      logic [WIDTH-1:0]  wdata_q;
      always_ff @(posedge clk) begin
        same_q <= re && we && (raddr == waddr);
        if (re && we && (raddr == waddr)) begin
          wmask_q <= wmask;
          wdata_q <= wdata;
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
    end else begin : g_rf
      assign rdata = m_rdata;
    end
  end
`else
  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [WIDTH-1:0] rdata_q;
`ifndef SYNTHESIS
  initial begin
    for (int i = 0; i < DEPTH; i++) mem_q[i] = INIT_VAL;
  end
`endif
  logic             same_addr;
  assign same_addr = re && we && (raddr == waddr);

  if (MASK_W == 1) begin : g_whole
    always_ff @(posedge clk) begin
      if (we && wmask[0]) mem_q[waddr] <= wdata;
      if (re) begin
        if (WRITE_FIRST && same_addr && wmask[0]) rdata_q <= wdata;
        else                                      rdata_q <= mem_q[raddr];
      end
    end
  end else begin : g_masked
    always_ff @(posedge clk) begin
      if (we) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (wmask[m]) mem_q[waddr][m * SEG_W +: SEG_W] <= wdata[m * SEG_W +: SEG_W];
        end
      end
      if (re) begin
        for (int m = 0; m < MASK_W; m++) begin
          if (WRITE_FIRST && same_addr && wmask[m])
            rdata_q[m * SEG_W +: SEG_W] <= wdata[m * SEG_W +: SEG_W];
          else
            rdata_q[m * SEG_W +: SEG_W] <= mem_q[raddr][m * SEG_W +: SEG_W];
        end
      end
    end
  end

  assign rdata = rdata_q;
`endif

endmodule
`default_nettype wire
