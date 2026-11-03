// Ref: front-end/BPU/target_predictor/BTB_top.h  BTB_TOP (one bank)
`default_nettype none

// One BTB bank: 4-way BTB, BHT (8-bit histories), target cache TC and TC-pre (2 ways) + a mode counter per BHT entry.
// Prediction and update may share a cycle; both read the START-of-cycle arrays, writes land at the clock edge.
module bpu_btb_bank import bpu_pkg::*; import bpu_btb_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [BPC_W-1:0]    pred_pc,          // bank pc = pc>>3
  input  logic [2:0]          pred_type_in,
  input  logic                upd_valid,
  input  logic [BPC_W-1:0]    upd_pc,
  input  logic [31:0]         upd_actual_addr,
  input  logic [2:0]          upd_br_type_in,
  input  logic                upd_actual_dir,
  output logic [31:0]         pred_target
);

  localparam int TC_DEPTH  = 1 << TC_IDX_W;
  localparam int BTB_DEPTH = 1 << B_IDX_W;
  localparam int BHT_DEPTH = 1 << BHT_W;

  logic [31:0]        pred_pc32;
  logic [31:0]        upd_pc32;
  // prediction-side indices
  logic [B_IDX_W-1:0] pred_btb_idx;
  logic [BHT_W-1:0]   pred_bht_idx;
  logic [TC_IDX_W-1:0] pred_tc_idx;
  // update-side indices and requests
  logic [B_IDX_W-1:0] upd_btb_idx;
  logic [BHT_W-1:0]   upd_bht_idx;
  logic [TC_IDX_W-1:0] upd_tc_pred_idx;
  logic [TC_IDX_W-1:0] upd_tc_write_idx;
  logic               bht_we;
  logic [BHT_DW-1:0]  bht_wdata;
  logic               btb_we;
  logic [1:0]         btb_way;
  btb_ent_t           btb_wdata;
  logic               tc_we;
  logic [0:0]         tc_way;
  tc_ent_t            tc_wdata;
  logic               tc_pre_we;
  logic [0:0]         tc_pre_way;
  tc_ent_t            tc_pre_wdata;
  logic               tc_mode_we;
  logic [2:0]         tc_mode_wdata;
  // array read data
  btb_ent_t           pred_btb_set [B_WAYS];
  btb_ent_t           upd_btb_set  [B_WAYS];
  logic [BHT_DW-1:0]  pred_bht_data;
  logic [BHT_DW-1:0]  upd_bht_data;
  tc_ent_t            pred_tc_set      [TC_WAYS];
  tc_ent_t            pred_tc_pre_set  [TC_WAYS];
  tc_ent_t            upd_tc_set       [TC_WAYS];
  tc_ent_t            upd_tc_pred_set  [TC_WAYS];
  tc_ent_t            upd_tc_pre_set   [TC_WAYS];
  logic [2:0]         pred_tc_mode;
  logic [2:0]         upd_tc_mode;

  always_comb begin
    pred_pc32    = {{(32 - BPC_W){1'b0}}, pred_pc};
    upd_pc32     = {{(32 - BPC_W){1'b0}}, upd_pc};
    pred_btb_idx = btb_idx_of(pred_pc32);
    pred_bht_idx = bht_idx_of(pred_pc32);
    pred_tc_idx  = tc_idx_of(pred_pc32, pred_bht_data);
  end

  // ---- BTB ways: 2 read ports (prediction, update), 1 write port ----
  for (genvar w = 0; w < B_WAYS; w++) begin : g_btb
    logic [B_IDX_W-1:0] rd_addr [2];
    btb_ent_t           rd_data [2];
    logic               wr_en   [1];
    logic [B_IDX_W-1:0] wr_addr [1];
    btb_ent_t           wr_data [1];
    always_comb begin
      rd_addr[0] = pred_btb_idx;
      rd_addr[1] = upd_btb_idx;
      wr_en[0]   = btb_we && (btb_way == 2'(w));
      wr_addr[0] = upd_btb_idx;
      wr_data[0] = btb_wdata;
    end
    bpu_mem #(.T(btb_ent_t), .DEPTH(BTB_DEPTH), .N_RD(2), .N_WR(1)) u_mem (
      .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    assign pred_btb_set[w] = rd_data[0];
    assign upd_btb_set[w]  = rd_data[1];
  end

  // ---- BHT and TC mode (indexed by the BHT index) ----
  if (1) begin : g_bht
    logic [BHT_W-1:0]  rd_addr [2];
    logic [BHT_DW-1:0] rd_data [2];
    logic              wr_en   [1];
    logic [BHT_W-1:0]  wr_addr [1];
    logic [BHT_DW-1:0] wr_data [1];
    always_comb begin
      rd_addr[0] = pred_bht_idx;
      rd_addr[1] = upd_bht_idx;
      wr_en[0]   = bht_we;
      wr_addr[0] = upd_bht_idx;
      wr_data[0] = bht_wdata;
    end
    bpu_mem #(.W(BHT_DW), .DEPTH(BHT_DEPTH), .N_RD(2), .N_WR(1)) u_mem (
      .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    assign pred_bht_data = rd_data[0];
    assign upd_bht_data  = rd_data[1];
  end

  if (1) begin : g_mode
    logic [BHT_W-1:0] rd_addr [2];
    logic [2:0]       rd_data [2];
    logic             wr_en   [1];
    logic [BHT_W-1:0] wr_addr [1];
    logic [2:0]       wr_data [1];
    always_comb begin
      rd_addr[0] = pred_bht_idx;
      rd_addr[1] = upd_bht_idx;
      wr_en[0]   = tc_mode_we;
      wr_addr[0] = upd_bht_idx;
      wr_data[0] = tc_mode_wdata;
    end
    bpu_mem #(.W(3), .DEPTH(BHT_DEPTH), .N_RD(2), .N_WR(1), .INIT(TC_MODE_INIT)) u_mem (
      .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    assign pred_tc_mode = rd_data[0];
    assign upd_tc_mode  = rd_data[1];
  end

  // ---- TC (3 read ports: prediction, update-write set, update-prediction set) and TC-pre (2 read ports) ----
  for (genvar w = 0; w < TC_WAYS; w++) begin : g_tc
    logic [TC_IDX_W-1:0] rd_addr [3];
    tc_ent_t             rd_data [3];
    logic                wr_en   [1];
    logic [TC_IDX_W-1:0] wr_addr [1];
    tc_ent_t             wr_data [1];
    logic [TC_IDX_W-1:0] pre_rd_addr [2];
    tc_ent_t             pre_rd_data [2];
    logic                pre_wr_en   [1];
    logic [TC_IDX_W-1:0] pre_wr_addr [1];
    tc_ent_t             pre_wr_data [1];
    always_comb begin
      rd_addr[0]     = pred_tc_idx;
      rd_addr[1]     = upd_tc_write_idx;
      rd_addr[2]     = upd_tc_pred_idx;
      wr_en[0]       = tc_we && (tc_way == 1'(w));
      wr_addr[0]     = upd_tc_write_idx;
      wr_data[0]     = tc_wdata;
      pre_rd_addr[0] = pred_tc_idx;
      pre_rd_addr[1] = upd_tc_pred_idx;
      pre_wr_en[0]   = tc_pre_we && (tc_pre_way == 1'(w));
      pre_wr_addr[0] = upd_tc_pred_idx;
      pre_wr_data[0] = tc_pre_wdata;
    end
    bpu_mem #(.T(tc_ent_t), .DEPTH(TC_DEPTH), .N_RD(3), .N_WR(1)) u_tc (
      .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    bpu_mem #(.T(tc_ent_t), .DEPTH(TC_DEPTH), .N_RD(2), .N_WR(1)) u_pre (
      .clk(clk), .rst_n(rst_n), .rd_addr(pre_rd_addr), .rd_data(pre_rd_data), .wr_en(pre_wr_en),
      .wr_addr(pre_wr_addr), .wr_data(pre_wr_data)
    );
    assign pred_tc_set[w]     = rd_data[0];
    assign upd_tc_set[w]      = rd_data[1];
    assign upd_tc_pred_set[w] = rd_data[2];
    assign pred_tc_pre_set[w] = pre_rd_data[0];
    assign upd_tc_pre_set[w]  = pre_rd_data[1];
  end

  bpu_btb_pred u_pred (
    .pc(pred_pc32), .br_type(pred_type_in), .btb_set(pred_btb_set), .tc_set(pred_tc_set),
    .tc_pre_set(pred_tc_pre_set), .tc_mode(pred_tc_mode), .pred_target(pred_target)
  );

  bpu_btb_upd u_upd (
    .upd_valid(upd_valid), .upd_pc(upd_pc32), .upd_actual_addr(upd_actual_addr), .upd_br_type(upd_br_type_in),
    .upd_actual_dir(upd_actual_dir), .btb_set(upd_btb_set), .bht_old(upd_bht_data), .tc_set(upd_tc_set),
    .tc_pred_set(upd_tc_pred_set), .tc_pre_set(upd_tc_pre_set), .tc_mode_old(upd_tc_mode),
    .btb_idx(upd_btb_idx), .bht_idx(upd_bht_idx), .tc_pred_idx(upd_tc_pred_idx), .tc_write_idx(upd_tc_write_idx),
    .bht_we(bht_we), .bht_wdata(bht_wdata), .btb_we(btb_we), .btb_way(btb_way), .btb_wdata(btb_wdata),
    .tc_we(tc_we), .tc_way(tc_way), .tc_wdata(tc_wdata), .tc_pre_we(tc_pre_we), .tc_pre_way(tc_pre_way),
    .tc_pre_wdata(tc_pre_wdata), .tc_mode_we(tc_mode_we), .tc_mode_wdata(tc_mode_wdata)
  );

endmodule

`default_nettype wire
