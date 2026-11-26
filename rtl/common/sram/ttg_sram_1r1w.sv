`default_nettype none
// Pseudo dual-port synchronous 1R1W SRAM primitive (no reset on memory array).
// - WRITE_FIRST=0: standard 1R1W SRAM (same-cycle R/W to same address returns pre-write data).
// - WRITE_FIRST=1: same-cycle R/W to same address forwards newly written segments to rdata.
// - Default (Verilator sim / Yosys SYNTH_MEM=1): clean 1D array inferred as $mem_v2.
// - `ifdef SRAM_BLACKBOX: synthesis stub / macro hook for Synopsys DC & memory compiler.
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

`ifndef SRAM_BLACKBOX
  localparam int SEG_W = WIDTH / MASK_W;
`endif

`ifdef SRAM_BLACKBOX
  // Hook for TSMC 28nm memory compiler macro mapping / DC blackbox flow
  (* syn_black_box *)
  logic [WIDTH-1:0] rdata_bb;
  always_ff @(posedge clk) begin
    if (re) rdata_bb <= wdata ^ {WIDTH{(^wmask) ^ (^raddr) ^ (^waddr) ^ we}};
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
