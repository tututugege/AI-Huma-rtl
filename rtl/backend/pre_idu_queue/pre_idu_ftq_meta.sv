// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[] (FTQTrainMetaEntry), comb_commit_info
`default_nettype none

// FTQ training-metadata storage: one ftq_meta_t per fetch slot of every entry. One write port (an allocation),
// COMMIT_WIDTH read ports addressed by the committing instruction's (ftq_idx, ftq_offset).
// The reference model walks a cursor from the FTQ head and asserts cursor == commit ftq_idx, so reading by the
// commit's own ftq_idx is identical on every reachable input.
module pre_idu_ftq_meta import ttg_cfg_pkg::*; import pre_idu_pkg::*; (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    wr_idx,
  input  ftq_meta_t                   wr_meta [BACKEND_FETCH_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx [COMMIT_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] rd_offset [COMMIT_WIDTH],
  output ftq_meta_t                   rd_meta [COMMIT_WIDTH]
);

  ftq_meta_t meta_q [FTQ_SIZE][BACKEND_FETCH_WIDTH];
  ftq_meta_t meta_d [FTQ_SIZE][BACKEND_FETCH_WIDTH];

  // Ref: comb_accept_front (ftq_train_meta_fifo_1[alloc_idx] = entry)
  always_comb begin
    for (int e = 0; e < FTQ_SIZE; e++) begin
      for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) begin
        meta_d[e][s] = (wr_en && wr_idx == FTQ_IDX_WIDTH'(e)) ? wr_meta[s] : meta_q[e][s];
      end
    end
  end

  // Ref: comb_commit_info
  always_comb begin
    for (int p = 0; p < COMMIT_WIDTH; p++) rd_meta[p] = meta_q[rd_idx[p]][rd_offset[p]];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int e = 0; e < FTQ_SIZE; e++) begin
        for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) meta_q[e][s] <= '0;
      end
    end else begin
      for (int e = 0; e < FTQ_SIZE; e++) begin
        for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) meta_q[e][s] <= meta_d[e][s];
      end
    end
  end

endmodule

`default_nettype wire
