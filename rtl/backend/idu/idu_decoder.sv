// Ref: back-end/Idu.cpp  class Idu::decode + the per-slot part of Idu::comb_decode
`default_nettype none

// One decode lane: instruction-buffer entry -> uop fields (everything except br_id / br_mask / valid).
// Entry invalid -> all-zero uop; page-fault entry -> NOP uop carrying the faulting inst in diag_val.
module idu_decoder import ttg_cfg_pkg::*; (
  input  logic                        entry_valid,
  input  logic [31:0]                 entry_inst,
  input  logic                        entry_page_fault_inst,
  input  logic [FTQ_IDX_WIDTH-1:0]    entry_ftq_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] entry_ftq_offset,
  input  logic                        entry_ftq_is_last,
  output logic [31:0]                 uop_diag_val,
  output logic [AREG_IDX_WIDTH-1:0]   uop_dest_areg,
  output logic [AREG_IDX_WIDTH-1:0]   uop_src1_areg,
  output logic [AREG_IDX_WIDTH-1:0]   uop_src2_areg,
  output logic [FTQ_IDX_WIDTH-1:0]    uop_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] uop_ftq_offset,
  output logic                        uop_ftq_is_last,
  output logic [4:0]                  uop_type,
  output logic                        uop_dest_en,
  output logic                        uop_src1_en,
  output logic                        uop_src2_en,
  output logic                        uop_is_atomic,
  output logic                        uop_src1_is_pc,
  output logic                        uop_src2_is_imm,
  output logic [2:0]                  uop_func3,
  output logic [6:0]                  uop_func7,
  output logic [31:0]                 uop_imm,
  output logic [CSR_IDX_WIDTH-1:0]    uop_csr_idx,
  output logic                        uop_page_fault_inst,
  output logic                        uop_illegal_inst,
  output logic                        uop_tma_is_ret,
  output logic                        uop_tma_mem_commit_is_load,
  output logic                        uop_tma_mem_commit_is_store,
  output logic                        is_branch              // valid decoded BR/JALR (needs a branch tag)
);

  // raw decode of the instruction word, as if the entry were a normal valid instruction
  logic [4:0]  raw_type;
  logic        raw_dest_en, raw_src1_en, raw_src2_en, raw_src1_is_pc, raw_src2_is_imm, raw_is_atomic;
  logic [2:0]  raw_func3;
  logic [5:0]  raw_dest_areg, raw_src1_areg, raw_src2_areg;
  logic        raw_illegal_inst, raw_is_branch, raw_is_ret, raw_is_load, raw_is_store;
  logic [6:0]  raw_imm_sel;
  logic [31:0] raw_imm;
  logic        decoded_en;     // entry valid and not a page fault: the decoded fields reach the output

  idu_ctrl_decode u_ctrl (
    .inst(entry_inst), .uop_type(raw_type), .dest_en(raw_dest_en), .src1_en(raw_src1_en), .src2_en(raw_src2_en),
    .src1_is_pc(raw_src1_is_pc), .src2_is_imm(raw_src2_is_imm), .is_atomic(raw_is_atomic), .func3(raw_func3),
    .dest_areg(raw_dest_areg), .src1_areg(raw_src1_areg), .src2_areg(raw_src2_areg),
    .illegal_inst(raw_illegal_inst), .is_branch(raw_is_branch), .imm_sel(raw_imm_sel),
    .tma_is_ret(raw_is_ret), .tma_mem_commit_is_load(raw_is_load), .tma_mem_commit_is_store(raw_is_store)
  );

  idu_imm_gen u_imm (.inst(entry_inst[31:7]), .imm_sel(raw_imm_sel), .imm(raw_imm));

  // Ref: Idu::comb_decode (uop = {} ; page_fault -> NOP with diag_val = inst ; else decode())
  always_comb begin
    decoded_en                  = entry_valid & ~entry_page_fault_inst;
    uop_diag_val                = entry_inst & {32{entry_valid}};
    uop_page_fault_inst         = entry_valid & entry_page_fault_inst;
    uop_ftq_idx                 = entry_ftq_idx & {FTQ_IDX_WIDTH{entry_valid}};
    uop_ftq_offset              = entry_ftq_offset & {FTQ_OFFSET_WIDTH{entry_valid}};
    uop_ftq_is_last             = entry_ftq_is_last & entry_valid;
    uop_type                    = raw_type & {5{decoded_en}};
    uop_dest_en                 = raw_dest_en & decoded_en;
    uop_src1_en                 = raw_src1_en & decoded_en;
    uop_src2_en                 = raw_src2_en & decoded_en;
    uop_is_atomic               = raw_is_atomic & decoded_en;
    uop_src1_is_pc              = raw_src1_is_pc & decoded_en;
    uop_src2_is_imm             = raw_src2_is_imm & decoded_en;
    uop_func3                   = raw_func3 & {3{decoded_en}};
    uop_func7                   = entry_inst[31:25] & {7{decoded_en}};
    uop_imm                     = raw_imm & {32{decoded_en}};
    uop_csr_idx                 = entry_inst[31:20] & {CSR_IDX_WIDTH{decoded_en}};
    uop_dest_areg               = raw_dest_areg & {AREG_IDX_WIDTH{decoded_en}};
    uop_src1_areg               = raw_src1_areg & {AREG_IDX_WIDTH{decoded_en}};
    uop_src2_areg               = raw_src2_areg & {AREG_IDX_WIDTH{decoded_en}};
    uop_illegal_inst            = raw_illegal_inst & decoded_en;
    uop_tma_is_ret              = raw_is_ret & decoded_en;
    uop_tma_mem_commit_is_load  = raw_is_load & decoded_en;
    uop_tma_mem_commit_is_store = raw_is_store & decoded_en;
    is_branch                   = raw_is_branch & decoded_en;
  end

endmodule

`default_nettype wire
