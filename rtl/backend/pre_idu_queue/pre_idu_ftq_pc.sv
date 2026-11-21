// Ref: back-end/PreIduQueue.cpp  ftq_lookup_entries[] (FTQEntry), ftq_pc() (2-taken discontinuity next_pc)
`default_nettype none

module pre_idu_ftq_pc import ttg_cfg_pkg::*; import pre_idu_pkg::*; #(
  parameter int NPORT = FTQ_PRF_PC_PORT_NUM + FTQ_ROB_PC_PORT_NUM + COMMIT_WIDTH
) (
  input  logic                         clk,
  input  logic                         wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     wr_idx,
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_valid,
  input  logic [XLEN_BITS-1:0]         wr_slot_pc [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_pred_taken,
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_is_rvc,
  input  logic [XLEN_BITS-1:0]         wr_next_pc,
  input  logic [FTQ_IDX_WIDTH-1:0]     rd_idx [NPORT],
  input  logic [FTQ_OFFSET_WIDTH-1:0]  rd_offset [NPORT],
  input  logic [FTQ_IDX_WIDTH-1:0]     dis_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0]  dis_off [DECODE_WIDTH],
  output logic [XLEN_BITS-1:0]         dis_pc [DECODE_WIDTH],
  output logic                         dis_is_rvc [DECODE_WIDTH],
  output logic [XLEN_BITS-1:0]         rd_pc [NPORT],
  output logic                         rd_pred_taken [NPORT],
  output logic                         rd_is_rvc [NPORT],
  output logic [XLEN_BITS-1:0]         rd_next_pc [NPORT]
);

  logic [XLEN_BITS-1:0]           slot_pc_q    [FTQ_SIZE][BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] pred_taken_q [FTQ_SIZE];
  logic [BACKEND_FETCH_WIDTH-1:0] is_rvc_q     [FTQ_SIZE];
  logic [XLEN_BITS-1:0]           next_pc_q    [FTQ_SIZE];
  logic [4:0]                     nslots_q     [FTQ_SIZE];

  logic [4:0] wr_nslots;
  always_comb begin
    wr_nslots = 5'd0;
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) if (wr_valid[i]) wr_nslots = 5'(i + 1);
  end

  always_comb begin
    for (int p = 0; p < DECODE_WIDTH; p++) begin
      dis_is_rvc[p] = is_rvc_q[dis_idx[p]][dis_off[p]];
      dis_pc[p]     = slot_pc_q[dis_idx[p]][dis_off[p]];
    end
  end

  always_comb begin
    for (int p = 0; p < NPORT; p++) begin
      logic [FTQ_IDX_WIDTH-1:0]    idx;
      logic [FTQ_OFFSET_WIDTH-1:0] off, off_p1;
      logic [XLEN_BITS-1:0]        pc_cur, pc_nxt;
      idx    = rd_idx[p];
      off    = rd_offset[p];
      off_p1 = off + FTQ_OFFSET_WIDTH'(1);
      pc_cur = slot_pc_q[idx][off];
      pc_nxt = slot_pc_q[idx][off_p1];

      rd_pc[p]         = pc_cur;
      rd_pred_taken[p] = pred_taken_q[idx][off];
      rd_is_rvc[p]     = is_rvc_q[idx][off];
      if (pred_taken_q[idx][off] && (({1'b0, off} + 5'd1) < nslots_q[idx]) &&
          (pc_nxt != (pc_cur + (is_rvc_q[idx][off] ? XLEN_BITS'(2) : XLEN_BITS'(4)))))
        rd_next_pc[p] = pc_nxt;
      else
        rd_next_pc[p] = next_pc_q[idx];
    end
  end

  always_ff @(posedge clk) begin
    if (wr_en) begin
      for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) slot_pc_q[wr_idx][s] <= wr_slot_pc[s];
      pred_taken_q[wr_idx] <= wr_pred_taken;
      is_rvc_q[wr_idx]     <= wr_is_rvc;
      next_pc_q[wr_idx]    <= wr_next_pc;
      nslots_q[wr_idx]     <= wr_nslots;
    end
  end

endmodule

`default_nettype wire
