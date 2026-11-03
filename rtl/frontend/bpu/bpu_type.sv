// Ref: front-end/BPU/type_predictor/TypePredictor.h  class TypePredictor
`default_nettype none

// Branch type predictor.  table[bank][set][way] lives in two bpu_mem arrays (one per way), address {bank, set}.
// 8 prediction lanes + 8 update lanes read the START-of-cycle table; the 8 update lanes write at the clock edge in lane
// order (a later lane overwrites an earlier one that picked the same slot, like the sequential C++ write loop).
module bpu_type import bpu_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        pred_valid  [NLANE],
  input  logic [31:0] pred_pc     [NLANE],
  input  logic        upd_valid   [NCOMMIT],
  input  logic [31:0] upd_pc      [NCOMMIT],
  input  logic [2:0]  upd_br_type [NCOMMIT],
  output logic [2:0]  pred_type   [NLANE]
);

  localparam int NRD = NLANE + NCOMMIT;

  // lane decode: bank = pc[4:2], set = (pc>>5) & 511, tag = (pc>>14) & 255   (bank pc = pc>>3, word = bank pc>>2)
  logic [TP_MEM_W-1:0] pred_addr [NLANE];
  logic [TP_MEM_W-1:0] upd_addr  [NCOMMIT];
  logic [TP_TAG_W-1:0] pred_tag  [NLANE];
  logic [TP_TAG_W-1:0] upd_tag   [NCOMMIT];
  logic [TP_MEM_W-1:0] rd_addr   [NRD];
  tp_entry_t           rd_data0  [NRD];
  tp_entry_t           rd_data1  [NRD];
  tp_entry_t           pred_entry [NLANE][TP_WAYS];
  tp_entry_t           upd_entry_rd [NCOMMIT][TP_WAYS];
  logic                lane_we    [NCOMMIT];
  logic [0:0]          lane_way   [NCOMMIT];
  tp_entry_t           lane_entry [NCOMMIT];
  logic                wr_en0     [NCOMMIT];
  logic                wr_en1     [NCOMMIT];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0]          upd_pred_type_unused [NCOMMIT];   // update lanes do not use the prediction output
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    for (int l = 0; l < NLANE; l++) begin
      pred_addr[l] = {pred_pc[l][4:2], pred_pc[l][5 +: TP_SET_W]};
      pred_tag[l]  = pred_pc[l][5 + TP_SET_W +: TP_TAG_W];
    end
    for (int l = 0; l < NCOMMIT; l++) begin
      upd_addr[l] = {upd_pc[l][4:2], upd_pc[l][5 +: TP_SET_W]};
      upd_tag[l]  = upd_pc[l][5 + TP_SET_W +: TP_TAG_W];
    end
    for (int l = 0; l < NLANE; l++)   rd_addr[l]         = pred_addr[l];
    for (int l = 0; l < NCOMMIT; l++) rd_addr[NLANE + l] = upd_addr[l];
    for (int l = 0; l < NLANE; l++) begin
      pred_entry[l][0] = rd_data0[l];
      pred_entry[l][1] = rd_data1[l];
    end
    for (int l = 0; l < NCOMMIT; l++) begin
      upd_entry_rd[l][0] = rd_data0[NLANE + l];
      upd_entry_rd[l][1] = rd_data1[NLANE + l];
    end
    for (int l = 0; l < NCOMMIT; l++) begin
      wr_en0[l] = upd_valid[l] && lane_we[l] && (lane_way[l] == 1'b0);
      wr_en1[l] = upd_valid[l] && lane_we[l] && (lane_way[l] == 1'b1);
    end
  end

  bpu_mem #(.T(tp_entry_t), .DEPTH(1 << TP_MEM_W), .N_RD(NRD), .N_WR(NCOMMIT)) u_way0 (
    .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data0),
    .wr_en(wr_en0), .wr_addr(upd_addr), .wr_data(lane_entry)
  );
  bpu_mem #(.T(tp_entry_t), .DEPTH(1 << TP_MEM_W), .N_RD(NRD), .N_WR(NCOMMIT)) u_way1 (
    .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data1),
    .wr_en(wr_en1), .wr_addr(upd_addr), .wr_data(lane_entry)
  );

  for (genvar l = 0; l < NLANE; l++) begin : g_pred
    logic [2:0] lane_type;
    /* verilator lint_off UNUSEDSIGNAL */
    logic       pred_unused_we;
    logic [0:0] pred_unused_way;
    tp_entry_t   pred_unused_entry;
    /* verilator lint_on UNUSEDSIGNAL */
    bpu_type_lane u_lane (
      .tag(pred_tag[l]), .way_entry(pred_entry[l]), .actual_type(BR_NONCTL),
      .pred_type(lane_type), .upd_we(pred_unused_we), .upd_way(pred_unused_way), .upd_entry(pred_unused_entry)
    );
    assign pred_type[l] = pred_valid[l] ? lane_type : BR_NONCTL;
  end

  for (genvar l = 0; l < NCOMMIT; l++) begin : g_upd
    bpu_type_lane u_lane (
      .tag(upd_tag[l]), .way_entry(upd_entry_rd[l]), .actual_type(upd_br_type[l]),
      .pred_type(upd_pred_type_unused[l]), .upd_we(lane_we[l]), .upd_way(lane_way[l]), .upd_entry(lane_entry[l])
    );
  end

endmodule

`default_nettype wire
