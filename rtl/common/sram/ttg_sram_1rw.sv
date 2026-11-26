`default_nettype none
// Single-port synchronous 1RW SRAM primitive (no reset on memory array).
// - Default (Verilator sim / Yosys SYNTH_MEM=1): clean 1D array inferred as $mem_v2.
// - `ifdef SRAM_BLACKBOX: synthesis stub / macro hook for Synopsys DC & memory compiler.
module ttg_sram_1rw #(
  parameter int    DEPTH  = 256,
  parameter int    WIDTH  = 64,
  parameter int    MASK_W = 1,
  /* verilator lint_off UNUSEDPARAM */
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

`ifndef SRAM_BLACKBOX
  localparam int SEG_W = WIDTH / MASK_W;
`endif

`ifdef SRAM_BLACKBOX
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
