`default_nettype none
// Ref: docs/modules/common.md section 4.1 (SRAM reset sweep). RTL only (the trace-model has no reset sequence).
// Reset stretcher: rst_n_o stays low while rst_n_i is low and for SRAM_SWEEP_CYCLES cycles after rst_n_i rises,
// so every SRAM wrapper below it sees a reset long enough to sweep its whole array. init_done = rst_n_o (registered).
module ttg_rst_sweep import ttg_sram_pkg::*;
(
  input  logic clk,
  input  logic rst_n_i,     // external reset (already synchronous to clk)
  output logic rst_n_o,     // stretched reset of the design
  output logic init_done
);
  localparam int CW = $clog2(SRAM_SWEEP_CYCLES + 1);
  logic [CW-1:0] cnt_q;
  logic          done_q;

  always_ff @(posedge clk) begin
    if (!rst_n_i) begin
      cnt_q  <= '0;
      done_q <= 1'b0;
    end else if (!done_q) begin
      cnt_q  <= cnt_q + CW'(1);
      done_q <= (cnt_q == CW'(SRAM_SWEEP_CYCLES - 1));
    end
  end

  assign rst_n_o   = done_q;
  assign init_done = done_q;
endmodule
`default_nettype wire
