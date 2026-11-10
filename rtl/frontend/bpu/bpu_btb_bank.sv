// Ref: front-end/BPU/target_predictor/BTB_top.h  BTB_TOP (one bank), Btb::read
`default_nettype none

// One BTB bank: 4-way BTB (256 sets) and the ITT (NITT tables of 2^ITT_IDX_W entries).  All arrays are read in S1
// with the indices of the block (BTB: hash of the bank pc, ITT table k: low bits of the TAGE index of table
// ITT_TBL[k]) and have a second read port for the update.  Prediction and update may share a cycle; both read the
// START-of-cycle arrays, writes land at the clock edge.
module bpu_btb_bank import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // S1 read
  input  logic [BPC_W-1:0]    rd_pc,            // bank pc = pc>>3
  input  logic [NITT-1:0][ITT_IDX_W-1:0] rd_itt_idx,
  output btb_ent_t            rd_btb [B_WAYS],
  output itt_ent_t [NITT-1:0] rd_itt,
  // update
  input  logic                upd_valid,
  input  logic [BPC_W-1:0]    upd_pc,
  input  logic [31:0]         upd_actual_addr,
  input  logic [2:0]          upd_br_type_in,
  input  logic                upd_actual_dir,
  input  logic [NITT-1:0][ITT_IDX_W-1:0] upd_itt_idx,
  input  logic [NITT-1:0][T_TAG_W-1:0]   upd_itt_tag
);

  localparam int BTB_DEPTH = 1 << B_IDX_W;
  localparam int ITT_DEPTH = 1 << ITT_IDX_W;

  logic [31:0]        rd_pc32;
  logic [31:0]        upd_pc32;
  logic [B_IDX_W-1:0] rd_btb_idx;
  logic [B_IDX_W-1:0] upd_btb_idx;
  logic               btb_we;
  logic [1:0]         btb_way;
  btb_ent_t           btb_wdata;
  logic [NITT-1:0]    itt_we;
  itt_ent_t [NITT-1:0] itt_wdata;
  btb_ent_t           upd_btb_set [B_WAYS];
  itt_ent_t [NITT-1:0] upd_itt_ent;

  always_comb begin
    rd_pc32    = {{(32 - BPC_W){1'b0}}, rd_pc};
    upd_pc32   = {{(32 - BPC_W){1'b0}}, upd_pc};
    rd_btb_idx = btb_idx_of(rd_pc32);
  end

  for (genvar w = 0; w < B_WAYS; w++) begin : g_btb
    logic [B_IDX_W-1:0] rd_addr [2];
    btb_ent_t           rd_data [2];
    logic               wr_en   [1];
    logic [B_IDX_W-1:0] wr_addr [1];
    btb_ent_t           wr_data [1];
    always_comb begin
      rd_addr[0] = rd_btb_idx;
      rd_addr[1] = upd_btb_idx;
      wr_en[0]   = btb_we && (btb_way == 2'(w));
      wr_addr[0] = upd_btb_idx;
      wr_data[0] = btb_wdata;
    end
    bpu_mem #(.T(btb_ent_t), .DEPTH(BTB_DEPTH), .N_RD(2), .N_WR(1)) u_mem (
      .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    assign rd_btb[w]      = rd_data[0];
    assign upd_btb_set[w] = rd_data[1];
  end

  for (genvar k = 0; k < NITT; k++) begin : g_itt
    logic [ITT_IDX_W-1:0] rd_addr [2];
    itt_ent_t             rd_data [2];
    logic                 wr_en   [1];
    logic [ITT_IDX_W-1:0] wr_addr [1];
    itt_ent_t             wr_data [1];
    always_comb begin
      rd_addr[0] = rd_itt_idx[k];
      rd_addr[1] = upd_itt_idx[k];
      wr_en[0]   = itt_we[k];
      wr_addr[0] = upd_itt_idx[k];
      wr_data[0] = itt_wdata[k];
    end
    bpu_mem #(.T(itt_ent_t), .DEPTH(ITT_DEPTH), .N_RD(2), .N_WR(1)) u_mem (
      .clk(clk), .rst_n(rst_n), .rd_addr(rd_addr), .rd_data(rd_data),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );
    assign rd_itt[k]      = rd_data[0];
    assign upd_itt_ent[k] = rd_data[1];
  end

  bpu_btb_upd u_upd (
    .upd_valid(upd_valid), .upd_pc(upd_pc32), .upd_actual_addr(upd_actual_addr), .upd_br_type(upd_br_type_in),
    .upd_actual_dir(upd_actual_dir), .upd_itt_tag(upd_itt_tag), .btb_set(upd_btb_set), .itt_old(upd_itt_ent),
    .btb_idx(upd_btb_idx), .btb_we(btb_we), .btb_way(btb_way), .btb_wdata(btb_wdata), .itt_we(itt_we),
    .itt_wdata(itt_wdata)
  );

endmodule

`default_nettype wire
