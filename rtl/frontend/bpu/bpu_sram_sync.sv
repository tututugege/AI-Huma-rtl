// Strict 1-cycle synchronous SRAM wrapper for BPU arrays (N_RD replicated 1R1W SRAMs sharing 1 write port).
// Every backing bank is an explicit `ttg_sram_1r1w` macro with full `SRAM_BLACKBOX` support.
`default_nettype none

module bpu_sram_sync #(
  parameter int    W           = 8,
  parameter int    DEPTH       = 1024,
  parameter int    N_RD        = 1,
  parameter type   T           = logic [W-1:0],
  parameter logic [W-1:0] INIT = '0,
  parameter logic [N_RD-1:0] WF_MASK = '0,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG        = "BPU_SRAM"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                     clk,
  input  logic                     rd_en   [N_RD],
  input  logic [$clog2(DEPTH)-1:0] rd_addr [N_RD],
  output T                         rd_data [N_RD],
  input  logic                     wr_en,
  input  logic [$clog2(DEPTH)-1:0] wr_addr,
  input  T                         wr_data
);

  localparam int EW = $bits(T);
  logic [EW-1:0] wdata_raw;
  assign wdata_raw = EW'(wr_data);

  for (genvar r = 0; r < N_RD; r++) begin : g_rd
    logic [EW-1:0] rdata_raw;
    ttg_sram_1r1w #(
      .DEPTH      (DEPTH),
      .WIDTH      (EW),
      .MASK_W     (1),
      .WRITE_FIRST(WF_MASK[r]),
      .INIT_VAL   (EW'(INIT)),
      .TAG        (TAG)
    ) u_sram (
      .clk  (clk),
      .re   (rd_en[r]),
      .raddr(rd_addr[r]),
      .rdata(rdata_raw),
      .we   (wr_en),
      .waddr(wr_addr),
      .wdata(wdata_raw),
      .wmask(1'b1)
    );
    assign rd_data[r] = T'(rdata_raw);
  end

`ifndef SYNTHESIS
  if ((DEPTH & (DEPTH - 1)) != 0) begin : g_pow2_check
    $error("bpu_sram_sync DEPTH must be a power of 2");
  end
`endif

endmodule

`default_nettype wire
