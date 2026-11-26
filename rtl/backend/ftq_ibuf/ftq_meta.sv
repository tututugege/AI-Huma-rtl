// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[] (FTQTrainMetaEntry), comb_commit_info
`default_nettype none

// FTQ training-metadata storage: compact per-entry {blk_id, is_pair, a_len} + 4b per-slot {alt_pred, pcpn}.
// One write port (an allocation), COMMIT_WIDTH read ports addressed by the committing instruction's (ftq_idx, ftq_offset).
module pre_idu_ftq_meta import ttg_cfg_pkg::*; import pre_idu_pkg::*; (
  input  logic                        clk,
  input  logic                        wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    wr_idx,
  input  logic [BLK_ID_W-1:0]         wr_blk_id,
  input  logic                        wr_is_pair,
  input  logic [3:0]                  wr_a_len,
  input  ftq_meta_t                   wr_meta [BACKEND_FETCH_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx [COMMIT_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] rd_offset [COMMIT_WIDTH],
  output ftq_meta_t                   rd_meta [COMMIT_WIDTH],
  output logic [BLK_ID_W-1:0]         rd_blk_id [COMMIT_WIDTH]
);

  ftq_meta_entry_t meta_q [FTQ_SIZE];

  // Ref: comb_commit_info
  always_comb begin
    for (int p = 0; p < COMMIT_WIDTH; p++) begin
      ftq_meta_entry_t e;
      e            = meta_q[rd_idx[p]];
      rd_meta[p]   = e.slots[rd_offset[p]];
      rd_blk_id[p] = (e.is_pair && (rd_offset[p] >= e.a_len)) ? (e.blk_id + BLK_ID_W'(1)) : e.blk_id;
    end
  end

  // Ref: comb_accept_front (ftq_train_meta_fifo_1[alloc_idx] = entry). Memory write; no reset.
  always_ff @(posedge clk) begin
    if (wr_en) begin
      meta_q[wr_idx].blk_id  <= wr_blk_id;
      meta_q[wr_idx].is_pair <= wr_is_pair;
      meta_q[wr_idx].a_len   <= wr_a_len;
      for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) meta_q[wr_idx].slots[s] <= wr_meta[s];
    end
  end

endmodule

`default_nettype wire
