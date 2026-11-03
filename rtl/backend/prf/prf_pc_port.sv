// Ref: back-end/Prf.cpp  get_prf_ftq_slot / Prf::comb_req_ftq / PC part of Prf::comb_read
`default_nettype none

// Fixed wiring between issue lanes and FTQ PC-read ports: the ALU lanes (only uops that use the PC as source 1)
// take ports 0..ALU_NUM-1, the branch lanes take ports ALU_NUM..ALU_NUM+BRU_NUM-1. Other lanes never read the PC.
// The FTQ answer is attached back to the requesting lane; without an answer the PC fields are zero.
module prf_pc_port import ttg_cfg_pkg::*; #(
  // UopType encoding width = ceil(log2(MAX_UOP_TYPE=18)) (base_types.h); not exported by ttg_cfg_pkg
  parameter int UOP_TYPE_WIDTH = 5,
  parameter int NALU  = ALU_NUM,
  parameter int NBR   = BRU_NUM
) (
  // issued uops on the ALU lanes / branch lanes
  input  logic [NALU-1:0]             alu_valid,
  input  logic [UOP_TYPE_WIDTH-1:0]   alu_op         [NALU],
  input  logic [NALU-1:0]             alu_src1_is_pc,
  input  logic [FTQ_IDX_WIDTH-1:0]    alu_ftq_idx    [NALU],
  input  logic [FTQ_OFFSET_WIDTH-1:0] alu_ftq_offset [NALU],
  input  logic [NBR-1:0]              br_valid,
  input  logic [UOP_TYPE_WIDTH-1:0]   br_op          [NBR],
  input  logic [FTQ_IDX_WIDTH-1:0]    br_ftq_idx     [NBR],
  input  logic [FTQ_OFFSET_WIDTH-1:0] br_ftq_offset  [NBR],
  // FTQ answers: ports 0..NALU-1 serve the ALU lanes, NALU.. serve the branch lanes
  input  logic [NALU+NBR-1:0]         resp_valid,
  input  logic [31:0]                 resp_pc        [NALU+NBR],
  input  logic [NALU+NBR-1:0]         resp_pred_taken,
  input  logic [31:0]                 resp_next_pc   [NALU+NBR],
  // requests to the FTQ
  output logic [NALU+NBR-1:0]         req_valid,
  output logic [FTQ_IDX_WIDTH-1:0]    req_ftq_idx    [NALU+NBR],
  output logic [FTQ_OFFSET_WIDTH-1:0] req_ftq_offset [NALU+NBR],
  // answers attached to the lanes
  output logic [31:0]                 alu_pc         [NALU],
  output logic [NALU-1:0]             alu_ftq_resp_valid,
  output logic [NALU-1:0]             alu_ftq_pred_taken,
  output logic [31:0]                 alu_ftq_next_pc [NALU],
  output logic [31:0]                 br_pc          [NBR],
  output logic [NBR-1:0]              br_ftq_resp_valid,
  output logic [NBR-1:0]              br_ftq_pred_taken,
  output logic [31:0]                 br_ftq_next_pc [NBR]
);

  localparam logic [31:0] ALU_OP_MASK = 32'(OP_MASK_ALU);
  localparam logic [31:0] BR_OP_MASK  = 32'(OP_MASK_BR);

  logic [NALU-1:0] alu_wants_pc;
  logic [NBR-1:0]  br_wants_pc;

  // Ref: get_prf_ftq_slot -- request conditions
  always_comb begin
    for (int i = 0; i < NALU; i++) alu_wants_pc[i] = alu_valid[i] && ALU_OP_MASK[alu_op[i]] && alu_src1_is_pc[i];
    for (int i = 0; i < NBR;  i++) br_wants_pc[i]  = br_valid[i] && BR_OP_MASK[br_op[i]];
  end

  // Ref: Prf::comb_req_ftq -- one port per lane, payload zero when not requesting
  for (genvar i = 0; i < NALU; i++) begin : g_alu
    assign req_valid[i]      = alu_wants_pc[i];
    assign req_ftq_idx[i]    = alu_wants_pc[i] ? alu_ftq_idx[i]    : '0;
    assign req_ftq_offset[i] = alu_wants_pc[i] ? alu_ftq_offset[i] : '0;

    // Ref: Prf::comb_read -- attach the FTQ answer
    logic got;
    assign got                   = alu_wants_pc[i] && resp_valid[i];
    assign alu_pc[i]             = got ? resp_pc[i]      : '0;
    assign alu_ftq_resp_valid[i] = got;
    assign alu_ftq_pred_taken[i] = got && resp_pred_taken[i];
    assign alu_ftq_next_pc[i]    = got ? resp_next_pc[i] : '0;
  end

  for (genvar i = 0; i < NBR; i++) begin : g_br
    localparam int P = NALU + i;
    assign req_valid[P]      = br_wants_pc[i];
    assign req_ftq_idx[P]    = br_wants_pc[i] ? br_ftq_idx[i]    : '0;
    assign req_ftq_offset[P] = br_wants_pc[i] ? br_ftq_offset[i] : '0;

    logic got;
    assign got                  = br_wants_pc[i] && resp_valid[P];
    assign br_pc[i]             = got ? resp_pc[P]      : '0;
    assign br_ftq_resp_valid[i] = got;
    assign br_ftq_pred_taken[i] = got && resp_pred_taken[P];
    assign br_ftq_next_pc[i]    = got ? resp_next_pc[P] : '0;
  end

endmodule

`default_nettype wire
