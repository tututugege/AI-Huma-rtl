// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[].meta.blk_id (block ID written at S2 + branch kind written at PD)
`default_nettype none

module ftq_bpu import ttg_cfg_pkg::*; import front_pkg::KIND_W; import bpu_types_pkg::FTB_BLK_ID_W; (
  input  logic                        clk,
  // S2 write port (at s2_idx)
  input  logic                        s2_wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    s2_idx,
  input  logic [FTB_BLK_ID_W-1:0]     s2_blk_id,
  input  logic                        s2_is_pair,
  input  logic [3:0]                  s2_a_len,
  // PD write port (at pd_idx)
  input  logic                        pd_fire,
  input  logic [FTQ_IDX_WIDTH-1:0]    pd_idx,
  input  logic [FETCH_WIDTH-1:0][KIND_W-1:0] pd_kind,
  // Mispredict lookup port
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] rd_offset,
  output logic [FTB_BLK_ID_W-1:0]     rd_blk,
  output logic [2:0]                  rd_type
);

  typedef struct packed {
    logic [FTB_BLK_ID_W-1:0] blk_id;
    logic                    is_pair;
    logic [3:0]              a_len;
  } id_rec_t;

  id_rec_t                            id_q   [FTQ_SIZE];
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] kind_q [FTQ_SIZE];

  id_rec_t                            id_r;
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] kind_r;

  always_comb begin
    id_r    = id_q[rd_idx];
    kind_r  = kind_q[rd_idx];
    rd_blk  = (id_r.is_pair && (rd_offset >= id_r.a_len)) ? (id_r.blk_id + FTB_BLK_ID_W'(1)) : id_r.blk_id;
    rd_type = kind_r[rd_offset];
  end

  always_ff @(posedge clk) begin
    if (s2_wr_en) id_q[s2_idx]   <= '{blk_id: s2_blk_id, is_pair: s2_is_pair, a_len: s2_a_len};
    if (pd_fire)  kind_q[pd_idx] <= pd_kind;
  end

endmodule

`default_nettype wire
