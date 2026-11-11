// Ref: back-end/Prf.cpp  Prf::comb_write
`default_nettype none

// Write ports -> per-register write enable and data. A physical register has a single producer in flight, so at most
// one write-back lane targets a register per cycle (reference model: later lane would win; never happens, see notes).
// Writes to p0 are harmless because every read of p0 returns 0.
module prf_write_arb import ttg_cfg_pkg::*; #(
  parameter int LANES = ISSUE_WIDTH,
  parameter int NREG  = PRF_NUM
) (
  input  logic [LANES-1:0]         wb_wen,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [LANES],
  input  logic [XLEN_BITS-1:0]              wb_result    [LANES],
  output logic [NREG-1:0]          reg_wr_en,
  output logic [XLEN_BITS-1:0]              reg_wr_data  [NREG]
);

  for (genvar p = 0; p < NREG; p++) begin : g_reg
    logic [LANES-1:0] lane_hits;
    always_comb begin
      for (int i = 0; i < LANES; i++) lane_hits[i] = wb_wen[i] && (wb_dest_preg[i] == PRF_IDX_WIDTH'(p));
    end
    ttg_onehot_mux #(.N(LANES), .W(XLEN_BITS)) u_data (.sel(lane_hits), .data(wb_result), .out(reg_wr_data[p]));
    assign reg_wr_en[p] = |lane_hits;
  end

endmodule

`default_nettype wire
