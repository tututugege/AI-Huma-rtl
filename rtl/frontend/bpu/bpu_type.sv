// Ref: front-end/BPU/type_predictor/TypePredictor.h  class TypePredictor (read / select split, one lane per bank)
`default_nettype none

// Branch type predictor, table[bank][set][way] in two bpu_mem arrays (one per way), address {bank, set}.
//   S1: bank b reads the two ways of the set of its slot (rd_pc[b], a pc whose bank field is b); the raw entries are
//       registered by the caller and compared with the tag in the compare stage (bpu_type_lane).
//   update: lane b is the update of bank b, taken from the update queue, at most one per bank and cycle; it reads the
//       START-of-cycle set and writes at the clock edge.
module bpu_type import ttg_cfg_pkg::*; import bpu_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [XLEN_BITS-1:0] rd_pc       [NBANK],
  output tp_entry_t   rd_way      [NBANK][TP_WAYS],
  input  logic [NBANK-1:0] upd_valid,
  input  logic [XLEN_BITS-1:0] upd_pc      [NBANK],
  input  logic [2:0]  upd_br_type [NBANK]
);

  localparam int NRD = NBANK + NBANK;

  logic [TP_MEM_W-1:0] rd_addr_s1 [NBANK];
  logic [TP_MEM_W-1:0] upd_addr   [NBANK];
  logic [TP_TAG_W-1:0] upd_tag    [NBANK];
  logic [TP_MEM_W-1:0] rd_addr    [NRD];
  tp_entry_t           rd_data0   [NRD];
  tp_entry_t           rd_data1   [NRD];
  tp_entry_t           upd_entry_rd [NBANK][TP_WAYS];
  logic [NBANK-1:0]    lane_we;
  logic [0:0]          lane_way   [NBANK];
  tp_entry_t           lane_entry [NBANK];
  logic                wr_en0     [NBANK];
  logic                wr_en1     [NBANK];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0]          upd_pred_type_unused [NBANK];   // update lanes do not use the prediction output
  /* verilator lint_on UNUSEDSIGNAL */

  // lane decode: bank = pc[4:2], set = (pc>>5) & 511, tag = (pc>>14) & 255
  always_comb begin
    for (int l = 0; l < NBANK; l++) begin
      rd_addr_s1[l] = {rd_pc[l][4:2], rd_pc[l][5 +: TP_SET_W]};
      upd_addr[l]   = {upd_pc[l][4:2], upd_pc[l][5 +: TP_SET_W]};
      upd_tag[l]    = upd_pc[l][5 + TP_SET_W +: TP_TAG_W];
      rd_addr[l]         = rd_addr_s1[l];
      rd_addr[NBANK + l] = upd_addr[l];
      rd_way[l][0]       = rd_data0[l];
      rd_way[l][1]       = rd_data1[l];
      upd_entry_rd[l][0] = rd_data0[NBANK + l];
      upd_entry_rd[l][1] = rd_data1[NBANK + l];
      wr_en0[l] = upd_valid[l] && lane_we[l] && (lane_way[l] == 1'b0);
      wr_en1[l] = upd_valid[l] && lane_we[l] && (lane_way[l] == 1'b1);
    end
  end

  bpu_mem #(.T(tp_entry_t), .DEPTH(1 << TP_MEM_W), .N_RD(NRD), .N_WR(NBANK)) u_way0 (
    .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data0),
    .wr_en(wr_en0), .wr_addr(upd_addr), .wr_data(lane_entry)
  );
  bpu_mem #(.T(tp_entry_t), .DEPTH(1 << TP_MEM_W), .N_RD(NRD), .N_WR(NBANK)) u_way1 (
    .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data1),
    .wr_en(wr_en1), .wr_addr(upd_addr), .wr_data(lane_entry)
  );

  for (genvar l = 0; l < NBANK; l++) begin : g_upd
    bpu_type_lane u_lane (
      .tag(upd_tag[l]), .way_entry(upd_entry_rd[l]), .actual_type(upd_br_type[l]),
      .pred_type(upd_pred_type_unused[l]), .upd_we(lane_we[l]), .upd_way(lane_way[l]), .upd_entry(lane_entry[l])
    );
  end

endmodule

`default_nettype wire
