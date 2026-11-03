// Ref: back-end/Prf.cpp  get_prf_ftq_slot / Prf::comb_req_ftq / PC part of Prf::comb_read
`default_nettype none

// Fixed wiring between issue lanes and FTQ PC-read ports: the NALU ALU lanes (only uops that use the PC as source 1)
// own ports 0..NALU-1, the NBR branch lanes own ports NALU..NALU+NBR-1. Each lane simply takes the answer of its
// own port; the FTQ answers zero on a port nobody requested, and the request payload is only read with the valid.
module prf_pc_port import ttg_cfg_pkg::*; #(
  // UopType encoding width = ceil(log2(MAX_UOP_TYPE=18)) (base_types.h); not exported by ttg_cfg_pkg
  parameter int UOP_TYPE_WIDTH = 5,
  parameter int NALU = ALU_NUM,
  parameter int NBR  = BRU_NUM
) (
  input  logic [NALU-1:0]             alu_valid,
  input  logic [UOP_TYPE_WIDTH-1:0]   alu_op [NALU],
  input  logic [NALU-1:0]             alu_src1_is_pc,
  input  logic [NBR-1:0]              br_valid,
  input  logic [UOP_TYPE_WIDTH-1:0]   br_op  [NBR],
  output logic [NALU+NBR-1:0]         req_valid
);

  localparam logic [31:0] ALU_OP_MASK = 32'(OP_MASK_ALU);
  localparam logic [31:0] BR_OP_MASK  = 32'(OP_MASK_BR);

  // Ref: get_prf_ftq_slot -- which issued uops read the FTQ PC
  always_comb begin
    for (int i = 0; i < NALU; i++) req_valid[i]        = alu_valid[i] && ALU_OP_MASK[alu_op[i]] && alu_src1_is_pc[i];
    for (int i = 0; i < NBR;  i++) req_valid[NALU + i] = br_valid[i] && BR_OP_MASK[br_op[i]];
  end

endmodule

`default_nettype wire
