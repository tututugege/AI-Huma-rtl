`default_nettype none
// Single-port synchronous 1RW SRAM primitive (no reset on memory array).
// - Default (Verilator sim / Yosys SYNTH_MEM=1): clean 1D array inferred as $mem_v2.
// - `ifdef SYNTH_TSMC28_SRAM: direct instantiation of real TSMC 28nm HPC+ HS LVT 1RW macros (TEM5N28HPCPLVTA*M4SWSO).
// - `ifdef SRAM_BLACKBOX: synthesis stub / macro hook for Synopsys DC & memory compiler.
module ttg_sram_1rw #(
  parameter int    DEPTH  = 256,
  parameter int    WIDTH  = 64,
  parameter int    MASK_W = 1,
  /* verilator lint_off UNUSEDPARAM */
  parameter logic [WIDTH-1:0] INIT_VAL = '0,
  parameter [255:0] TAG   = "GENERIC"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                     clk,
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

`ifdef SYNTH_TSMC28_SRAM
  // Expand segment write mask to per-bit active-low BWEB for TSMC 28nm HS LVT 1RW macros
  logic [WIDTH-1:0] bit_wmask;
  always_comb begin
    for (int m = 0; m < MASK_W; m++) begin
      bit_wmask[m * SEG_W +: SEG_W] = {SEG_W{wmask[m]}};
    end
  end

  if (DEPTH <= 16) begin : g_small_ff
    // Tiny register-file arrays (e.g. 8x96b SC bias bank): synthesize directly to standard-cell FFs
    logic [WIDTH-1:0] mem_q [DEPTH];
    logic [WIDTH-1:0] rdata_q;
    always_ff @(posedge clk) begin
      if (en) begin
        if (we) begin
          for (int b = 0; b < WIDTH; b++) begin
            if (bit_wmask[b]) mem_q[addr][b] <= wdata[b];
          end
        end else begin
          rdata_q <= mem_q[addr];
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
      d_p[WIDTH-1:0]    = wdata;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA512X8M4SWSO u_lo (
      .CLK (clk), .CEB (~(en && !addr[9])), .WEB (~we),
      .A   (addr[8:0]), .D (d_p), .BWEB (bweb_p), .Q (q_lo),
      .SLP (1'b0), .SD (1'b0)
    );
    TEM5N28HPCPLVTA512X8M4SWSO u_hi (
      .CLK (clk), .CEB (~(en &&  addr[9])), .WEB (~we),
      .A   (addr[8:0]), .D (d_p), .BWEB (bweb_p), .Q (q_hi),
      .SLP (1'b0), .SD (1'b0)
    );
    always_ff @(posedge clk) begin
      if (en && !we) sel_hi_q <= addr[9];
    end
    assign rdata = sel_hi_q ? q_hi[WIDTH-1:0] : q_lo[WIDTH-1:0];
  end else if ((DEPTH == 512) && (WIDTH <= 8)) begin : g_512x8
    logic [7:0] d_p, bweb_p, q_p;
    always_comb begin
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA512X8M4SWSO u_macro (
      .CLK (clk), .CEB (~en), .WEB (~we),
      .A   (addr), .D (d_p), .BWEB (bweb_p), .Q (q_p),
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
        d_p[SW-1:0]    = wdata[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA512X72M4SWSO u_macro (
        .CLK (clk), .CEB (~en), .WEB (~we),
        .A   (addr), .D (d_p), .BWEB (bweb_p), .Q (q_p),
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
        d_p[SW-1:0]    = wdata[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA256X72M4SWSO u_macro (
        .CLK (clk), .CEB (~en), .WEB (~we),
        .A   (addr), .D (d_p), .BWEB (bweb_p), .Q (q_p),
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
        d_p[SW-1:0]    = wdata[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA256X64M4SWSO u_macro (
        .CLK (clk), .CEB (~en), .WEB (~we),
        .A   (addr), .D (d_p), .BWEB (bweb_p), .Q (q_p),
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
        d_p[SW-1:0]    = wdata[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA128X64M4SWSO u_macro (
        .CLK (clk), .CEB (~en), .WEB (~we),
        .A   (addr), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else if ((DEPTH <= 64) && (WIDTH <= 32)) begin : g_64x32
    logic [5:0]  a_p;
    logic [31:0] d_p, bweb_p, q_p;
    always_comb begin
      a_p    = '0;
      a_p[$clog2(DEPTH)-1:0] = addr;
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA64X32M4SWSO u_macro (
      .CLK (clk), .CEB (~en), .WEB (~we),
      .A   (a_p), .D (d_p), .BWEB (bweb_p), .Q (q_p),
      .SLP (1'b0), .SD (1'b0)
    );
    assign rdata = q_p[WIDTH-1:0];
  end else if ((DEPTH <= 64) && (WIDTH <= 58)) begin : g_64x58
    logic [5:0]  a_p;
    logic [57:0] d_p, bweb_p, q_p;
    always_comb begin
      a_p    = '0;
      a_p[$clog2(DEPTH)-1:0] = addr;
      d_p    = '0;
      bweb_p = '1;
      d_p[WIDTH-1:0]    = wdata;
      bweb_p[WIDTH-1:0] = ~bit_wmask;
    end
    TEM5N28HPCPLVTA64X58M4SWSO u_macro (
      .CLK (clk), .CEB (~en), .WEB (~we),
      .A   (a_p), .D (d_p), .BWEB (bweb_p), .Q (q_p),
      .SLP (1'b0), .SD (1'b0)
    );
    assign rdata = q_p[WIDTH-1:0];
  end else if (DEPTH <= 64) begin : g_64x64
    localparam int NT = (WIDTH + 63) / 64;
    logic [5:0] a_p;
    always_comb begin
      a_p = '0;
      a_p[$clog2(DEPTH)-1:0] = addr;
    end
    for (genvar t = 0; t < NT; t++) begin : g_t
      localparam int LO = t * 64;
      localparam int SW = ((LO + 64) <= WIDTH) ? 64 : (WIDTH - LO);
      logic [63:0] d_p, bweb_p, q_p;
      always_comb begin
        d_p    = '0;
        bweb_p = '1;
        d_p[SW-1:0]    = wdata[LO +: SW];
        bweb_p[SW-1:0] = ~bit_wmask[LO +: SW];
      end
      TEM5N28HPCPLVTA64X64M4SWSO u_macro (
        .CLK (clk), .CEB (~en), .WEB (~we),
        .A   (a_p), .D (d_p), .BWEB (bweb_p), .Q (q_p),
        .SLP (1'b0), .SD (1'b0)
      );
      assign rdata[LO +: SW] = q_p[SW-1:0];
    end
  end else begin : g_fallback_bb
    (* syn_black_box *)
    logic [WIDTH-1:0] rdata_bb;
    always_ff @(posedge clk) begin
      if (en && !we) rdata_bb <= wdata ^ {WIDTH{(^wmask) ^ (^addr)}};
    end
    assign rdata = rdata_bb;
  end
`elsif SRAM_BLACKBOX
  // Hook for TSMC 28nm memory compiler macro mapping / DC blackbox flow
  (* syn_black_box *)
  logic [WIDTH-1:0] rdata_bb;
  always_ff @(posedge clk) begin
    if (en && !we) rdata_bb <= wdata ^ {WIDTH{(^wmask) ^ (^addr)}};
  end
  assign rdata = rdata_bb;
`else
  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [WIDTH-1:0] rdata_q;
`ifndef SYNTHESIS
  initial begin
    for (int i = 0; i < DEPTH; i++) mem_q[i] = INIT_VAL;
  end
`endif

  if (MASK_W == 1) begin : g_whole
    always_ff @(posedge clk) begin
      if (en) begin
        if (we) begin
          if (wmask[0]) mem_q[addr] <= wdata;
        end else begin
          rdata_q <= mem_q[addr];
        end
      end
    end
  end else begin : g_masked
    always_ff @(posedge clk) begin
      if (en) begin
        if (we) begin
          for (int m = 0; m < MASK_W; m++) begin
            if (wmask[m]) mem_q[addr][m * SEG_W +: SEG_W] <= wdata[m * SEG_W +: SEG_W];
          end
        end else begin
          rdata_q <= mem_q[addr];
        end
      end
    end
  end

  assign rdata = rdata_q;
`endif

endmodule
`default_nettype wire
