// Ref: back-end/Prf.cpp  read_operand_with_bypass()
`default_nettype none

// One operand read port. Priority (highest first): execution-unit bypass (lowest FU index wins),
// write-back stage forward (highest lane index wins), register file. p0 / disabled source reads 0.
module prf_bypass import ttg_cfg_pkg::*; #(
  parameter int WB_LANES = ISSUE_WIDTH,
  parameter int FU_NUM   = TOTAL_FU_COUNT
) (
  input  logic                     src_en,
  input  logic [PRF_IDX_WIDTH-1:0] src_preg,
  input  logic [31:0]              rf_data,
  input  logic [WB_LANES-1:0]      wb_valid,
  input  logic [WB_LANES-1:0]      wb_dest_en,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [WB_LANES],
  input  logic [31:0]              wb_result    [WB_LANES],
  input  logic [FU_NUM-1:0]        fu_valid,
  input  logic [FU_NUM-1:0]        fu_dest_en,
  input  logic [PRF_IDX_WIDTH-1:0] fu_dest_preg [FU_NUM],
  input  logic [31:0]              fu_result    [FU_NUM],
  output logic [31:0]              rdata
);

  logic [WB_LANES-1:0] wb_hits;
  logic [WB_LANES-1:0] wb_hits_rev;
  logic [WB_LANES-1:0] wb_winner_rev;
  logic [WB_LANES-1:0] wb_winner;
  logic                wb_any;
  logic [31:0]         wb_data;
  logic [FU_NUM-1:0]   fu_hits;
  logic [FU_NUM-1:0]   fu_winner;
  logic                fu_any;
  logic [31:0]         fu_data;
  logic                read_zero;

  // Ref: read_operand_with_bypass -- tag compare against both forward sources
  always_comb begin
    read_zero = !src_en || (src_preg == '0);
    for (int i = 0; i < WB_LANES; i++) begin
      wb_hits[i]     = wb_valid[i] && wb_dest_en[i] && (wb_dest_preg[i] == src_preg);
      wb_hits_rev[i] = wb_hits[WB_LANES-1-i];
      wb_winner[i]   = wb_winner_rev[WB_LANES-1-i];
    end
    for (int k = 0; k < FU_NUM; k++) begin
      fu_hits[k] = fu_valid[k] && fu_dest_en[k] && (fu_dest_preg[k] == src_preg);
    end
  end

  ttg_first_set #(.N(WB_LANES)) u_wb_last (.req(wb_hits_rev), .onehot(wb_winner_rev), .any(wb_any));
  ttg_onehot_mux #(.N(WB_LANES), .W(32)) u_wb_data (.sel(wb_winner), .data(wb_result), .out(wb_data));
  ttg_first_set #(.N(FU_NUM)) u_fu_first (.req(fu_hits), .onehot(fu_winner), .any(fu_any));
  ttg_onehot_mux #(.N(FU_NUM), .W(32)) u_fu_data (.sel(fu_winner), .data(fu_result), .out(fu_data));

  always_comb begin
    if (read_zero)    rdata = '0;
    else if (fu_any)  rdata = fu_data;
    else if (wb_any)  rdata = wb_data;
    else              rdata = rf_data;
  end

endmodule

`default_nettype wire
