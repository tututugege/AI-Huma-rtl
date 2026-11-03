// Ref: (SRAM-style arrays of the BPU: TAGE/BTB/type tables, front-end/BPU/*)  bpu_mem
`default_nettype none

// Register-file style array: N_RD asynchronous read ports (they see the array as it was at the START of the cycle),
// N_WR synchronous write ports applied in index order at the clock edge (a higher port wins on the same address).
// Reset loads INIT into every entry.  Used instead of a q/d copy of the whole array: the arrays here are up to 4096
// entries x 16 bits and a full copy per cycle would make simulation orders of magnitude slower.
module bpu_mem #(
  parameter int W     = 8,
  parameter int DEPTH = 1024,
  parameter int N_RD  = 1,
  parameter int N_WR  = 1,
  parameter type T    = logic [W-1:0],   // element type (a packed struct of width W is fine)
  parameter T INIT    = '0
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [$clog2(DEPTH)-1:0] rd_addr [N_RD],
  output T                         rd_data [N_RD],
  input  logic                     wr_en   [N_WR],
  input  logic [$clog2(DEPTH)-1:0] wr_addr [N_WR],
  input  T                         wr_data [N_WR]
);

  T mem_q [DEPTH];

  for (genvar r = 0; r < N_RD; r++) begin : g_rd
    assign rd_data[r] = mem_q[rd_addr[r]];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < DEPTH; s++) mem_q[s] <= INIT;
    end else begin
      for (int p = 0; p < N_WR; p++) if (wr_en[p]) mem_q[wr_addr[p]] <= wr_data[p];
    end
  end

`ifndef SYNTHESIS
  if ((DEPTH & (DEPTH - 1)) != 0) begin : g_pow2_check
    $error("bpu_mem DEPTH must be a power of 2");
  end
`endif

endmodule

`default_nettype wire
