// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[].meta.blk_id (block ID + branch kind for BPU rec_q[256] repair)
`default_nettype none

module pre_idu_ftq_bpu import ttg_cfg_pkg::*; import front_pkg::KIND_W; import bpu_types_pkg::FTB_BLK_ID_W; (
  input  logic                        clk,
  input  logic                        wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    wr_idx,
  input  logic [FTB_BLK_ID_W-1:0]     wr_blk_id,
  input  logic                        wr_is_pair,
  input  logic [3:0]                  wr_a_len,
  input  logic [FETCH_WIDTH-1:0][KIND_W-1:0] wr_kind,
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] rd_offset,
  output logic [FTB_BLK_ID_W-1:0]     rd_blk,
  output logic [2:0]                  rd_type
);

  typedef struct packed {
    logic [FTB_BLK_ID_W-1:0]                  blk_id;
    logic                                     is_pair;
    logic [3:0]                               a_len;
    logic [FETCH_WIDTH-1:0][KIND_W-1:0]       kind;
  } rec_t;

  rec_t rec_q [FTQ_SIZE];
  rec_t rec;

  always_comb begin
    rec     = rec_q[rd_idx];
    rd_blk  = (rec.is_pair && (rd_offset >= rec.a_len)) ? (rec.blk_id + FTB_BLK_ID_W'(1)) : rec.blk_id;
    rd_type = rec.kind[rd_offset];
  end

  always_ff @(posedge clk) begin
    if (wr_en) rec_q[wr_idx] <= '{blk_id: wr_blk_id, is_pair: wr_is_pair, a_len: wr_a_len, kind: wr_kind};
  end

endmodule

`default_nettype wire
