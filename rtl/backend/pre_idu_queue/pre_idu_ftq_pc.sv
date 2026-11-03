// Ref: back-end/PreIduQueue.cpp  ftq_lookup_entries[] (FTQEntry), fill_ftq_pc_resp
`default_nettype none

// FTQ pc storage: per entry the pc of every fetch slot, the per-slot predicted-taken bit and the block's predicted
// next pc. One write port (an allocation), NPORT asynchronous read ports (Prf, Rob, commit-time).
module pre_idu_ftq_pc import ttg_cfg_pkg::*; import pre_idu_pkg::*; #(
  parameter int NPORT = FTQ_PRF_PC_PORT_NUM + FTQ_ROB_PC_PORT_NUM + COMMIT_WIDTH
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     wr_idx,
  input  logic [31:0]                  wr_slot_pc [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_pred_taken,
  input  logic [31:0]                  wr_next_pc,
  input  logic [FTQ_IDX_WIDTH-1:0]     rd_idx [NPORT],
  input  logic [FTQ_OFFSET_WIDTH-1:0]  rd_offset [NPORT],
  output logic [31:0]                  rd_pc [NPORT],
  output logic                         rd_pred_taken [NPORT],
  output logic [31:0]                  rd_next_pc [NPORT]
);

  logic [31:0]                    slot_pc_q [FTQ_SIZE][BACKEND_FETCH_WIDTH];
  logic [31:0]                    slot_pc_d [FTQ_SIZE][BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] pred_taken_q [FTQ_SIZE];
  logic [BACKEND_FETCH_WIDTH-1:0] pred_taken_d [FTQ_SIZE];
  logic [31:0]                    next_pc_q [FTQ_SIZE];
  logic [31:0]                    next_pc_d [FTQ_SIZE];

  // Ref: comb_accept_front (ftq_lookup_entries_1[alloc_idx] = entry)
  always_comb begin
    for (int e = 0; e < FTQ_SIZE; e++) begin
      for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) begin
        slot_pc_d[e][s] = (wr_en && wr_idx == FTQ_IDX_WIDTH'(e)) ? wr_slot_pc[s] : slot_pc_q[e][s];
      end
      pred_taken_d[e] = (wr_en && wr_idx == FTQ_IDX_WIDTH'(e)) ? wr_pred_taken : pred_taken_q[e];
      next_pc_d[e]    = (wr_en && wr_idx == FTQ_IDX_WIDTH'(e)) ? wr_next_pc : next_pc_q[e];
    end
  end

  // Ref: comb_ftq_lookup_prf / comb_ftq_lookup_rob / comb_commit_info (pc, pred_taken) -- reads the registered state
  always_comb begin
    for (int p = 0; p < NPORT; p++) begin
      rd_pc[p]         = slot_pc_q[rd_idx[p]][rd_offset[p]];
      rd_pred_taken[p] = pred_taken_q[rd_idx[p]][rd_offset[p]];
      rd_next_pc[p]    = next_pc_q[rd_idx[p]];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int e = 0; e < FTQ_SIZE; e++) begin
        for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) slot_pc_q[e][s] <= '0;
        pred_taken_q[e] <= '0;
        next_pc_q[e]    <= '0;
      end
    end else begin
      for (int e = 0; e < FTQ_SIZE; e++) begin
        for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) slot_pc_q[e][s] <= slot_pc_d[e][s];
        pred_taken_q[e] <= pred_taken_d[e];
        next_pc_q[e]    <= next_pc_d[e];
      end
    end
  end

endmodule

`default_nettype wire
