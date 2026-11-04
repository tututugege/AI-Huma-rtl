// Ref: front-end/BPU/target_predictor/BTB_top.h  class BTB_TOP (8 instances, one per BPU bank)
`default_nettype none

// The 8 BTB banks of the BPU.  Port convention = spec/bpu_btb.io (arrays indexed by bank).
module bpu_btb import bpu_pkg::*; (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [NBANK-1:0] pred_req,
  input  logic [BPC_W-1:0]  pred_pc         [NBANK],
  input  logic [2:0]        pred_type_in    [NBANK],
  input  logic [NBANK-1:0] upd_valid,
  input  logic [BPC_W-1:0]  upd_pc          [NBANK],
  input  logic [31:0]       upd_actual_addr [NBANK],
  input  logic [2:0]        upd_br_type_in  [NBANK],
  input  logic [NBANK-1:0] upd_actual_dir,
  output logic [31:0]       pred_target     [NBANK]
);

  // pred_req only qualifies pred_target (a lookup has no side effect), so it is not used inside the bank
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NBANK-1:0] pred_req_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    for (int b = 0; b < NBANK; b++) pred_req_unused[b] = pred_req[b];
  end

  for (genvar b = 0; b < NBANK; b++) begin : g_bank
    bpu_btb_bank u_bank (
      .clk(clk), .rst_n(rst_n), .pred_pc(pred_pc[b]), .pred_type_in(pred_type_in[b]), .upd_valid(upd_valid[b]),
      .upd_pc(upd_pc[b]), .upd_actual_addr(upd_actual_addr[b]), .upd_br_type_in(upd_br_type_in[b]),
      .upd_actual_dir(upd_actual_dir[b]), .pred_target(pred_target[b])
    );
  end

endmodule

`default_nettype wire
