// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[] (FTQTrainMetaEntry), comb_commit_info
`default_nettype none

// FTQ training-metadata storage: compact per-entry {blk_id, is_pair, a_len} + 4b per-slot {alt_pred, pcpn}.
// One write port (an allocation), COMMIT_WIDTH read ports addressed by the committing instruction's (ftq_idx, ftq_offset).
module ftq_meta import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; (
  input  logic                        clk,
  input  logic                        wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    wr_idx,
  input  logic [BLK_ID_W-1:0]         wr_blk_id,
  input  logic                        wr_is_pair,
  input  logic [3:0]                  wr_a_len,
  input  ftq_meta_t                   wr_meta [BACKEND_FETCH_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0]    ftq_head,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx [COMMIT_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTQ_OFFSET_WIDTH-1:0] rd_offset [COMMIT_WIDTH],
  output ftq_meta_t                   rd_meta [COMMIT_WIDTH],
  output logic [BLK_ID_W-1:0]         rd_blk_id [COMMIT_WIDTH]
);

  localparam int NB = 8;
  localparam int NL = FTQ_SIZE / NB;
  localparam int BW = $clog2(NB);
  localparam int LW = $clog2(NL);

  ftq_meta_entry_t bank_q [NB][NL];
  ftq_meta_entry_t win [NB];

  // 8-bank 8:1 sequential commit window anchored at ftq_head
  always_comb begin
    logic [BW-1:0] hb;
    logic [LW-1:0] hl;
    hb = ftq_head[BW-1:0];
    hl = ftq_head[FTQ_IDX_WIDTH-1:BW];
    for (int b = 0; b < NB; b++) begin
      logic [LW-1:0] r;
      r      = (BW'(b) < hb) ? (hl + LW'(1)) : hl;
      win[b] = bank_q[b][r];
    end
  end

  // Ref: comb_commit_info
  always_comb begin
    for (int p = 0; p < COMMIT_WIDTH; p++) begin
      ftq_meta_entry_t e;
      e            = win[rd_idx[p][BW-1:0]];
      rd_meta[p]   = e.slots[rd_offset[p]];
      rd_blk_id[p] = (e.is_pair && (rd_offset[p] >= e.a_len)) ? (e.blk_id + BLK_ID_W'(1)) : e.blk_id;
    end
  end

  // Ref: comb_accept_front (ftq_train_meta_fifo_1[alloc_idx] = entry). Memory write; no reset.
  always_ff @(posedge clk) begin
    if (wr_en) begin
      bank_q[wr_idx[BW-1:0]][wr_idx[FTQ_IDX_WIDTH-1:BW]].blk_id  <= wr_blk_id;
      bank_q[wr_idx[BW-1:0]][wr_idx[FTQ_IDX_WIDTH-1:BW]].is_pair <= wr_is_pair;
      bank_q[wr_idx[BW-1:0]][wr_idx[FTQ_IDX_WIDTH-1:BW]].a_len   <= wr_a_len;
      for (int s = 0; s < BACKEND_FETCH_WIDTH; s++)
        bank_q[wr_idx[BW-1:0]][wr_idx[FTQ_IDX_WIDTH-1:BW]].slots[s] <= wr_meta[s];
    end
  end

endmodule

`default_nettype wire
