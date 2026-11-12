// Ref: back-end/Prf.cpp  class Prf  (F/D: the FP physical registers, tags FP_TAG_BASE .. FP_TAG_BASE + FPRF_NUM - 1)
`default_nettype none

// FP register file with its write ports, write-back staging and operand read ports with bypass. The tag space is shared
// with the integer registers (the tag says which file); an FP write-back is a lane whose destination tag lies in the FP
// range. Read ports: NRD ports given by the caller (the FP issue ports' three sources and the store-data ports' data).
module prf_fp
  import ttg_cfg_pkg::*;
  import fp_pkg::*;
#(
  parameter int LANES   = ISSUE_WIDTH,
  parameter int BYP_NUM = TOTAL_FU_COUNT + LSU_LOAD_WB_WIDTH,
  parameter int NRD     = 1
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // write-back stage of the integer side (same timing): lane writes this cycle with destination tag
  input  logic [LANES-1:0]         wb_wen,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [LANES],
  input  logic [FW-1:0]            exe_fresult [LANES],    // FP result of this cycle's execution entries (staged here)
  // bypass sources of this cycle: execution-unit results and LSU write-back requests
  input  logic [BYP_NUM-1:0]       byp_wen,
  input  logic [PRF_IDX_WIDTH-1:0] byp_dest_preg [BYP_NUM],
  input  logic [FW-1:0]            byp_fresult [BYP_NUM],
  // operand read ports
  input  logic [NRD-1:0]           rd_en,
  input  logic [PRF_IDX_WIDTH-1:0] rd_preg [NRD],
  output logic [FW-1:0]            rd_data [NRD]
);

  logic [FW-1:0] wb_fres_q [LANES];     // write-back stage payload (like wb_result_q of the integer side)
  logic [FW-1:0] reg_file_q [FPRF_NUM];

  always_ff @(posedge clk) begin
    for (int i = 0; i < LANES; i++) begin
      if (!rst_n) wb_fres_q[i] <= '0;
      else        wb_fres_q[i] <= exe_fresult[i];
    end
  end

  // ---- write ports: a register has a single producer in flight, so at most one lane targets it per cycle ----
  for (genvar p = 0; p < FPRF_NUM; p++) begin : g_reg
    logic [LANES-1:0] lane_hits;
    logic [FW-1:0]    wdata;
    always_comb begin
      for (int i = 0; i < LANES; i++) lane_hits[i] = wb_wen[i] && (wb_dest_preg[i] == PRF_IDX_WIDTH'(FP_TAG_BASE + p));
    end
    ttg_onehot_mux #(.N(LANES), .W(FW)) u_data (.sel(lane_hits), .data(wb_fres_q), .out(wdata));
    always_ff @(posedge clk) begin
      if (!rst_n)          reg_file_q[p] <= '0;
      else if (|lane_hits) reg_file_q[p] <= wdata;
    end
  end

  // ---- read ports with bypass (write-back stage and execution-unit results, as on the integer side) ----
  for (genvar r = 0; r < NRD; r++) begin : g_rd
    logic [FW-1:0] rf_data;
    logic [PRF_IDX_WIDTH-1:0] idx;
    logic in_range;
    assign idx      = rd_preg[r] - PRF_IDX_WIDTH'(FP_TAG_BASE);
    assign in_range = (rd_preg[r] >= PRF_IDX_WIDTH'(FP_TAG_BASE)) && (idx < PRF_IDX_WIDTH'(FPRF_NUM));
    assign rf_data  = in_range ? reg_file_q[idx[$clog2(FPRF_NUM)-1:0]] : '0;
    logic [LANES-1:0] wb_hits;
    logic [BYP_NUM-1:0] fu_hits;
    logic [FW-1:0] wb_data, fu_data;
    always_comb begin
      for (int i = 0; i < LANES; i++) wb_hits[i] = wb_wen[i] && (wb_dest_preg[i] == rd_preg[r]);
      for (int k = 0; k < BYP_NUM; k++) fu_hits[k] = byp_wen[k] && (byp_dest_preg[k] == rd_preg[r]);
    end
    ttg_onehot_mux #(.N(LANES), .W(FW)) u_wb (.sel(wb_hits), .data(wb_fres_q), .out(wb_data));
    ttg_onehot_mux #(.N(BYP_NUM), .W(FW)) u_fu (.sel(fu_hits), .data(byp_fresult), .out(fu_data));
    always_comb begin
      if (!rd_en[r])                  rd_data[r] = '0;
      else if (|wb_hits || |fu_hits)  rd_data[r] = wb_data | fu_data;
      else                            rd_data[r] = rf_data;
    end
  end

endmodule

`default_nettype wire
