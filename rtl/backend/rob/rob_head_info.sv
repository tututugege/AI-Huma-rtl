// Ref: back-end/Rob.cpp  class Rob  (comb_ready stall, comb_ftq_pc_req, comb_commit head_* broadcast)
`default_nettype none

module rob_head_info
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                         empty,
  input  logic [ROB_LINE_IDX_W-1:0]    deq_ptr,
  input  logic [ROB_BANK_NUM-1:0]      head_valid,
  input  logic [ROB_BANK_NUM-1:0]      head_complete,
  input  logic [ROB_BANK_NUM-1:0]      head_flush,
  input  rob_entry_t                   head_uop [ROB_BANK_NUM],
  output logic                         rob2dis_stall,
  output logic                         ftq_req_valid,
  output logic [FTQ_IDX_WIDTH-1:0]     ftq_req_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0]  ftq_req_ftq_offset,
  output logic                         bcast_head_valid,
  output logic [ROB_IDX_WIDTH-1:0]     bcast_head_rob_idx,
  output logic                         bcast_head_incomplete_valid,
  output logic [ROB_IDX_WIDTH-1:0]     bcast_head_incomplete_rob_idx
);

  localparam int PC_REQ_W = FTQ_IDX_WIDTH + FTQ_OFFSET_WIDTH;

  logic [ROB_BANK_NUM-1:0]   first_valid, first_incomplete;
  logic                      any_valid, any_incomplete;
  logic [ROB_BANK_IDX_W-1:0] first_valid_bank, first_incomplete_bank;
  logic [PC_REQ_W-1:0]       pc_req_bank [ROB_BANK_NUM];
  logic [PC_REQ_W-1:0]       pc_req_bits;

  // "first valid slot" and "first valid-but-incomplete slot" of the head line (priority = lowest bank)
  ttg_first_set #(.N(ROB_BANK_NUM)) u_first_valid (
    .req(head_valid), .onehot(first_valid), .any(any_valid)
  );
  ttg_first_set #(.N(ROB_BANK_NUM)) u_first_incomplete (
    .req(head_valid & ~head_complete), .onehot(first_incomplete), .any(any_incomplete)
  );
  ttg_onehot_to_idx #(.N(ROB_BANK_NUM)) u_first_valid_idx (.onehot(first_valid), .idx(first_valid_bank));
  ttg_onehot_to_idx #(.N(ROB_BANK_NUM)) u_first_incomplete_idx (
    .onehot(first_incomplete), .idx(first_incomplete_bank)
  );

  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_bank
    assign pc_req_bank[b] = {head_uop[b].ftq_idx, head_uop[b].ftq_offset};
  end

  // Ref: Rob::comb_ftq_pc_req (no request while the ROB is empty)
  ttg_onehot_mux #(.N(ROB_BANK_NUM), .W(PC_REQ_W)) u_pc_req_mux (
    .sel(first_valid & {ROB_BANK_NUM{!empty}}), .data(pc_req_bank), .out(pc_req_bits)
  );

  // Ref: Rob::comb_ready, comb_commit
  always_comb begin
    rob2dis_stall                = |(head_valid & head_flush);
    ftq_req_valid                = !empty && any_valid;
    {ftq_req_ftq_idx, ftq_req_ftq_offset} = pc_req_bits;
    bcast_head_valid             = !empty && any_valid;
    bcast_head_rob_idx           = bcast_head_valid ? {deq_ptr, first_valid_bank} : '0;
    bcast_head_incomplete_valid  = !empty && any_incomplete;
    bcast_head_incomplete_rob_idx = bcast_head_incomplete_valid ? {deq_ptr, first_incomplete_bank} : '0;
  end

endmodule

`default_nettype wire
