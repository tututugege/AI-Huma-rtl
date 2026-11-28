// Ref: back-end/Prf.cpp  read_operand_with_bypass()
`default_nettype none

// One operand read port: the EXU-stage bypass is selected directly by a wakeup-driven one-hot mask (fu_sel,
// zero tag comparators on the EXU hot path); the registered write-back stage uses tag compare against wb_dest_preg.
// The LSU write-back requests of this cycle (speculative load wake-up) are a further tag-compared bypass source.
module prf_bypass import ttg_cfg_pkg::*; #(
  parameter int WBL         = WB_LANES,          // register write-back lanes (EXP-046)
  parameter int EXU_N       = ALU_NUM,           // wakeup-driven one-hot EXU bypass lanes (6 ALU-port winners)
  parameter int LSUB_N      = LSU_LOAD_WB_WIDTH,
  parameter int W           = XLEN_BITS          // data width
) (
  input  logic                     src_en,
  input  logic [PRF_IDX_WIDTH-1:0] src_preg,
  input  logic [W-1:0]             rf_data,
  input  logic [WBL-1:0]           wb_wen,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [WBL],
  input  logic [W-1:0]             wb_result    [WBL],
  input  logic [EXU_N-1:0]         fu_sel,
  input  logic [W-1:0]             fu_result    [EXU_N],
  input  logic [LSUB_N-1:0]        lsu_byp_valid,
  input  logic [PRF_IDX_WIDTH-1:0] lsu_byp_preg   [LSUB_N],
  input  logic [W-1:0]             lsu_byp_result [LSUB_N],
  output logic [W-1:0]             rdata
);

  logic [WBL-1:0]    wb_hits;
  logic [W-1:0]      wb_data;
  logic [W-1:0]      fu_data;
  logic [LSUB_N-1:0] lsu_hits;
  logic [W-1:0]      lsu_data;

  always_comb begin
    for (int i = 0; i < WBL; i++) wb_hits[i] = wb_wen[i] && (wb_dest_preg[i] == src_preg);
  end

  ttg_onehot_mux #(.N(WBL),   .W(W)) u_wb_data (.sel(wb_hits), .data(wb_result), .out(wb_data));
  ttg_onehot_mux #(.N(EXU_N), .W(W)) u_fu_data (.sel(fu_sel),  .data(fu_result), .out(fu_data));

  always_comb begin
    for (int i = 0; i < LSUB_N; i++) lsu_hits[i] = lsu_byp_valid[i] && (lsu_byp_preg[i] == src_preg);
  end
  ttg_onehot_mux #(.N(LSUB_N), .W(W)) u_lsu_data (.sel(lsu_hits), .data(lsu_byp_result), .out(lsu_data));

  always_comb begin
    if (!src_en || src_preg == '0)       rdata = '0;
    else if (|fu_sel)                    rdata = fu_data;
    else if (|lsu_hits)                  rdata = lsu_data;
    else if (|wb_hits)                   rdata = wb_data;
    else                                 rdata = rf_data;
  end

endmodule

`default_nettype wire
