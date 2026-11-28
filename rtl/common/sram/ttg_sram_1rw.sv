`default_nettype none
// Ref: (new common primitive) single-port synchronous 1RW SRAM; the model keeps plain arrays
// Single-port synchronous 1RW SRAM primitive (no reset on memory array).
// - INIT_SWEEP=1 (default): while rst_n is low the array is cleared to INIT_VAL, one address per cycle
//   (docs/modules/common.md 4.1); the reset must last DEPTH + 1 cycles (ttg_rst_sweep). No `initial` values:
//   simulation, synthesis and silicon start the same.
// - Default (Verilator sim / Yosys SYNTH_MEM=1): clean 1D array inferred as $mem_v2.
// - `ifdef SYNTH_TSMC28_SRAM: direct instantiation of real TSMC 28nm HPC+ HS LVT 1RW macros (TEM5N28HPCPLVTA*M4SWSO).
module ttg_sram_1rw import ttg_sram_pkg::*; #(
  parameter int    DEPTH  = 256,
  parameter int    WIDTH  = 64,
  parameter int    MASK_W = 1,
  /* verilator lint_off UNUSEDPARAM */
  parameter logic [WIDTH-1:0] INIT_VAL = '0,
  parameter bit    INIT_SWEEP = 1'b1,
  parameter [255:0] TAG   = "GENERIC"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,
  input  logic                     we,
  input  logic [$clog2(DEPTH)-1:0] addr,
  input  logic [WIDTH-1:0]         wdata,
  input  logic [MASK_W-1:0]        wmask,
  output logic [WIDTH-1:0]         rdata
);

  /* verilator lint_off UNUSEDPARAM */
  localparam int SEG_W = WIDTH / MASK_W;
  /* verilator lint_on UNUSEDPARAM */

  // ---- reset sweep: INIT_VAL -> mem[sw_q] every reset cycle; sw_q wraps, no reset on purpose ----
  localparam int AW = $clog2(DEPTH);
  logic          sweep;
  logic [AW-1:0] sw_q;
  logic          en_i, we_i;
  logic [AW-1:0] addr_i;
  logic [WIDTH-1:0]  wdata_i;
  logic [MASK_W-1:0] wmask_i;
  assign sweep   = INIT_SWEEP && !rst_n;
  assign en_i    = sweep ? 1'b1 : en;
  assign we_i    = sweep ? 1'b1 : we;
  assign addr_i  = sweep ? sw_q : addr;
  assign wdata_i = sweep ? INIT_VAL : wdata;
  assign wmask_i = sweep ? {MASK_W{1'b1}} : wmask;
  if (INIT_SWEEP) begin : g_sweep
    always_ff @(posedge clk) begin
      if (!rst_n) sw_q <= (sw_q >= AW'(DEPTH - 1)) ? '0 : sw_q + AW'(1);
    end
    if (DEPTH + 1 > SRAM_SWEEP_CYCLES) begin : g_too_deep
      $error("ttg_sram_1rw %0s: DEPTH %0d needs DEPTH + 1 reset cycles > SRAM_SWEEP_CYCLES %0d",
             TAG, DEPTH, SRAM_SWEEP_CYCLES);
    end
  end else begin : g_no_sweep
    always_ff @(posedge clk) sw_q <= '0;
  end

`ifdef SYNTH_TSMC28_SRAM
  // Expand segment write mask to per-bit active-low BWEB for TSMC 28nm HS LVT 1RW macros
  logic [WIDTH-1:0] bit_wmask;
  always_comb begin
    for (int m = 0; m < MASK_W; m++) begin
      bit_wmask[m * SEG_W +: SEG_W] = {SEG_W{wmask_i[m]}};
    end
  end

  if (DEPTH <= 16) begin : g_small_ff
    // Tiny register-file arrays (e.g. 8x96b SC bias bank): synthesize directly to standard-cell FFs
    logic [WIDTH-1:0] mem_q [DEPTH];
    logic [WIDTH-1:0] rdata_q;
    always_ff @(posedge clk) begin
      if (en_i) begin
        if (we_i) begin
          for (int b = 0; b < WIDTH; b++) begin
            if (bit_wmask[b]) mem_q[addr_i][b] <= wdata_i[b];
          end
        end else begin
          rdata_q <= mem_q[addr_i];
        end
      end
    end
    assign rdata = rdata_q;
  end else if ((DEPTH == 1024) && (WIDTH <= 8)) begin : g_1024x8
    // 1024x8b tiled as 2x 512x8 real TSMC 28nm HS LVT 1RW macros (MSB selects bank)
    logic [7:0] d_p, bweb_p, q_lo, q_hi;
    logic       sel_hi_q;
    always_comb begin
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata_i;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA512X8M4SWSO u_lo (
      .CLK (clk), .CEB (~(en_i && !addr_i[9])), .WEB (~we_i),
      .A   (addr_i[8:0]), .D (d_p), .BWEB (bweb_p), .Q (q_lo),
      .SLP (1'b0), .SD (1'b0)
    );
    TEM5N28HPCPLVTA512X8M4SWSO u_hi (
      .CLK (clk), .CEB (~(en_i &&  addr_i[9])), .WEB (~we_i),
      .A   (addr_i[8:0]), .D (d_p), .BWEB (bweb_p), .Q (q_hi),
      .SLP (1'b0), .SD (1'b0)
    );
    always_ff @(posedge clk) begin
      if (en_i && !we_i) sel_hi_q <= addr_i[9];
    end
    assign rdata = sel_hi_q ? q_hi[WIDTH-1:0] : q_lo[WIDTH-1:0];
  end else if (DEPTH == 1024) begin : g_1024x32
    localparam int NT = (WIDTH + 31) / 32;
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 32;
      localparam int SW = ((LO + 32) <= WIDTH) ? 32 : (WIDTH - LO);
      logic [31:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata_i[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA1024X32M4SWSO u_macro (
        .CLK (clk), .CEB (~en_i), .WEB (~we_i),
        .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if ((DEPTH == 512) && (WIDTH <= 8)) begin : g_512x8
    logic [7:0] d_p, bweb_p, q_p;
    always_comb begin
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata_i;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA512X8M4SWSO u_macro (
      .CLK (clk), .CEB (~en_i), .WEB (~we_i),
      .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
      .SLP (1'b0), .SD (1'b0)
    );
    assign rdata = q_p[WIDTH-1:0];
  end else if (DEPTH == 512) begin : g_512x72
    localparam int NT = (WIDTH + 71) / 72;
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 72;
      localparam int SW = ((LO + 72) <= WIDTH) ? 72 : (WIDTH - LO);
      logic [71:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata_i[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA512X72M4SWSO u_macro (
        .CLK (clk), .CEB (~en_i), .WEB (~we_i),
        .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if ((DEPTH == 256) && (WIDTH > 64)) begin : g_256x72
    localparam int NT = (WIDTH + 71) / 72;
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 72;
      localparam int SW = ((LO + 72) <= WIDTH) ? 72 : (WIDTH - LO);
      logic [71:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata_i[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA256X72M4SWSO u_macro (
        .CLK (clk), .CEB (~en_i), .WEB (~we_i),
        .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if (DEPTH == 256) begin : g_256x64
    localparam int NT = (WIDTH + 63) / 64;
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 64;
      localparam int SW = ((LO + 64) <= WIDTH) ? 64 : (WIDTH - LO);
      logic [63:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata_i[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA256X64M4SWSO u_macro (
        .CLK (clk), .CEB (~en_i), .WEB (~we_i),
        .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if (DEPTH == 128) begin : g_128x64
    localparam int NT = (WIDTH + 63) / 64;
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 64;
      localparam int SW = ((LO + 64) <= WIDTH) ? 64 : (WIDTH - LO);
      logic [63:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata_i[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA128X64M4SWSO u_macro (
        .CLK (clk), .CEB (~en_i), .WEB (~we_i),
        .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if ((DEPTH <= 64) && (WIDTH <= 32)) begin : g_64x32
    logic [5:0]  a_p;
    logic [31:0] d_p, bweb_p, q_p;
    always_comb begin
      a_p    = '0;
      a_p[$clog2(DEPTH)-1:0] = addr_i;
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata_i;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA64X32M4SWSO u_macro (
      .CLK (clk), .CEB (~en_i), .WEB (~we_i),
      .A   (a_p), .D (d_p), .BWEB (bweb_p), .Q (q_p),
      .SLP (1'b0), .SD (1'b0)
    );
    assign rdata = q_p[WIDTH-1:0];
  end else if ((DEPTH <= 64) && (WIDTH <= 58)) begin : g_64x58
    logic [5:0]  a_p;
    logic [57:0] d_p, bweb_p, q_p;
    always_comb begin
      a_p    = '0;
      a_p[$clog2(DEPTH)-1:0] = addr_i;
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata_i;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA64X58M4SWSO u_macro (
      .CLK (clk), .CEB (~en_i), .WEB (~we_i),
      .A   (a_p), .D (d_p), .BWEB (bweb_p), .Q (q_p),
      .SLP (1'b0), .SD (1'b0)
    );
    assign rdata = q_p[WIDTH-1:0];
  end else if (DEPTH <= 64) begin : g_64x64
    localparam int NT = (WIDTH + 63) / 64;
    logic [5:0] a_p;
    always_comb begin
      a_p = '0;
      a_p[$clog2(DEPTH)-1:0] = addr_i;
    end
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 64;
      localparam int SW = ((LO + 64) <= WIDTH) ? 64 : (WIDTH - LO);
      logic [63:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata_i[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA64X64M4SWSO u_macro (
        .CLK (clk), .CEB (~en_i), .WEB (~we_i),
        .A   (a_p), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if ((DEPTH == 1024) && (WIDTH <= 32)) begin : g_1024x32
    logic [31:0] d_p, bweb_p, q_p;
    always_comb begin
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata_i;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA1024X32M4SWSO u_macro (
      .CLK (clk), .CEB (~en_i), .WEB (~we_i),
      .A   (addr_i), .D (d_p), .BWEB (bweb_p), .Q (q_p),
      .SLP (1'b0), .SD (1'b0)
    );
    assign rdata = q_p[WIDTH-1:0];
  end else begin : g_tiled_512x72
    localparam int NB  = (DEPTH + 511) / 512;
    localparam int NT  = (WIDTH + 71) / 72;
    localparam int BKW = (NB > 1) ? $clog2(NB) : 1;
    logic [8:0]       sub_a;
    logic [BKW-1:0]   bk_sel, bk_q;
    logic [WIDTH-1:0] q_bk [NB];
    always_comb begin
      sub_a  = 9'(addr_i);
      bk_sel = (NB > 1) ? BKW'(addr_i >> 9) : BKW'(0);
    end
    for (genvar b = 0; b < NB; b++) begin : g_b
      logic bank_en;
      assign bank_en = en_i && (bk_sel == BKW'(b));
      for (genvar t = 0; t < NT; t++) begin : g_t
        localparam int LO = t * 72;
        localparam int SW = ((LO + 72) <= WIDTH) ? 72 : (WIDTH - LO);
        logic [71:0] d_p, bweb_p, q_p;
        always_comb begin
          d_p    = '0;
          bweb_p = '1;
          d_p[SW-1:0]    = wdata_i[LO +: SW];
          bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
        end
        TEM5N28HPCPLVTA512X72M4SWSO u_macro (
          .CLK (clk), .CEB (~bank_en), .WEB (~we_i),
          .A   (sub_a), .D (d_p), .BWEB (bweb_p), .Q (q_p),
          .SLP (1'b0), .SD (1'b0)
        );
        assign q_bk[b][LO +: SW] = q_p[SW-1:0];
      end
    end
    always_ff @(posedge clk) begin
      if (en_i && !we_i) bk_q <= bk_sel;
    end
    assign rdata = q_bk[bk_q];
  end
`else
  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [WIDTH-1:0] rdata_q;

  if (MASK_W == 1) begin : g_whole
    always_ff @(posedge clk) begin
      if (en_i) begin
        if (we_i) begin
          if (wmask_i[0]) mem_q[addr_i] <= wdata_i;
        end else begin
          rdata_q <= mem_q[addr_i];
        end
      end
    end
  end else begin : g_masked
    always_ff @(posedge clk) begin
      if (en_i) begin
        if (we_i) begin
          for (int m = 0; m < MASK_W; m++) begin
            if (wmask_i[m]) mem_q[addr_i][m * SEG_W +: SEG_W] <= wdata_i[m * SEG_W +: SEG_W];
          end
        end else begin
          rdata_q <= mem_q[addr_i];
        end
      end
    end
  end

  assign rdata = rdata_q;
`endif

endmodule
`default_nettype wire
