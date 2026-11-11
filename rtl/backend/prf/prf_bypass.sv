// Ref: back-end/Prf.cpp  read_operand_with_bypass()
`default_nettype none

// One operand read port: the value comes from an execution-unit bypass or the write-back stage if one of them
// produces the wanted register this cycle, else from the register file. A disabled source or p0 reads 0.
// A register has a single producer in flight, so at most one candidate matches (no priority needed).
module prf_bypass import ttg_cfg_pkg::*; #(
  parameter int WB_LANES = ISSUE_WIDTH,
  parameter int FU_NUM   = TOTAL_FU_COUNT
) (
  input  logic                     src_en,
  input  logic [PRF_IDX_WIDTH-1:0] src_preg,
  input  logic [XLEN_BITS-1:0]              rf_data,
  input  logic [WB_LANES-1:0]      wb_wen,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [WB_LANES],
  input  logic [XLEN_BITS-1:0]              wb_result    [WB_LANES],
  input  logic [FU_NUM-1:0]        fu_wen,
  input  logic [PRF_IDX_WIDTH-1:0] fu_dest_preg [FU_NUM],
  input  logic [XLEN_BITS-1:0]              fu_result    [FU_NUM],
  output logic [XLEN_BITS-1:0]              rdata
);

  logic [WB_LANES-1:0] wb_hits;
  logic [FU_NUM-1:0]   fu_hits;
  logic [XLEN_BITS-1:0]         wb_data;
  logic [XLEN_BITS-1:0]         fu_data;

  always_comb begin
    for (int i = 0; i < WB_LANES; i++) wb_hits[i] = wb_wen[i] && (wb_dest_preg[i] == src_preg);
    for (int k = 0; k < FU_NUM; k++)   fu_hits[k] = fu_wen[k] && (fu_dest_preg[k] == src_preg);
  end

  ttg_onehot_mux #(.N(WB_LANES), .W(XLEN_BITS)) u_wb_data (.sel(wb_hits), .data(wb_result), .out(wb_data));
  ttg_onehot_mux #(.N(FU_NUM),   .W(XLEN_BITS)) u_fu_data (.sel(fu_hits), .data(fu_result), .out(fu_data));

  always_comb begin
    if (!src_en || src_preg == '0)    rdata = '0;
    else if (|wb_hits || |fu_hits)    rdata = wb_data | fu_data;
    else                              rdata = rf_data;
  end

endmodule

`default_nettype wire
