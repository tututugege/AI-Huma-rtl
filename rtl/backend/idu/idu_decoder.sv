// Ref: back-end/Idu.cpp  class Idu::decode + the per-slot part of Idu::comb_decode
`default_nettype none

// One decode lane: instruction-buffer entry -> uop fields (everything except br_id / br_mask / valid).
// Uop fields are only consumed for a valid lane, so an invalid entry is simply decoded like any other word.
// A page-fault entry becomes a NOP uop carrying the faulting inst in diag_val.
module idu_decoder import ttg_cfg_pkg::*; (
  input  logic                        entry_valid,        // only qualifies is_branch
  input  logic [31:0]                 entry_inst,
  input  logic                        entry_page_fault_inst,
  input  logic [FTQ_IDX_WIDTH-1:0]    entry_ftq_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] entry_ftq_offset,
  input  logic                        entry_ftq_is_last,
  output logic [XLEN_BITS-1:0]                 uop_diag_val,
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
  output logic                        uop_is_word,
  output logic [2:0]                  uop_func3,
  output logic [6:0]                  uop_func7,
  output logic [31:0]                 uop_imm,
  output logic [CSR_IDX_WIDTH-1:0]    uop_csr_idx,
  output logic                        uop_page_fault_inst,
  output logic                        uop_illegal_inst,
  output logic                        uop_dest_fp,           // F/D domain bits (zero without an FP register file)
  output logic                        uop_src1_fp,
  output logic                        uop_src2_fp,
  output logic                        uop_src3_en,           // = src3_fp: fused multiply-add third source
  output logic [AREG_IDX_WIDTH-1:0]   uop_src3_areg,
  output logic [2:0]                  uop_fp_cls,
  output logic                        is_branch              // valid decoded BR/JALR (needs a branch tag)
);

  // raw decode of the instruction word, as if the entry were a normal valid instruction
  logic [4:0]  raw_type;
  logic        raw_dest_en, raw_src1_en, raw_src2_en, raw_src1_is_pc, raw_src2_is_imm, raw_is_word, raw_is_atomic;
  logic [2:0]  raw_func3;
  logic [5:0]  raw_dest_areg, raw_src1_areg, raw_src2_areg;
  logic        raw_illegal_inst, raw_is_branch;
  logic [6:0]  raw_imm_sel;
  logic        raw_dest_fp, raw_src1_fp, raw_src2_fp, raw_src3_en;
  logic [4:0]  raw_src3_areg;
  logic [2:0]  raw_fp_cls;
  logic [31:0] raw_imm;
  logic        decoded_en;     // not a page fault: decoded fields reach the output (page fault -> NOP uop)

  idu_ctrl_decode u_ctrl (
    .inst(entry_inst), .uop_type(raw_type), .dest_en(raw_dest_en), .src1_en(raw_src1_en), .src2_en(raw_src2_en),
    .src1_is_pc(raw_src1_is_pc), .src2_is_imm(raw_src2_is_imm), .is_word(raw_is_word), .is_atomic(raw_is_atomic),
    .func3(raw_func3),
    .dest_areg(raw_dest_areg), .src1_areg(raw_src1_areg), .src2_areg(raw_src2_areg),
    .illegal_inst(raw_illegal_inst), .is_branch(raw_is_branch), .imm_sel(raw_imm_sel),
    .dest_fp(raw_dest_fp), .src1_fp(raw_src1_fp), .src2_fp(raw_src2_fp), .src3_en(raw_src3_en),
    .src3_areg(raw_src3_areg), .fp_cls(raw_fp_cls)
  );

  idu_imm_gen u_imm (.inst(entry_inst[31:2]), .imm_sel(raw_imm_sel), .imm(raw_imm));

  // Ref: Idu::comb_decode (page_fault -> NOP with diag_val = inst ; else decode())
  always_comb begin
    decoded_en                  = ~entry_page_fault_inst;
    uop_diag_val                = XLEN_BITS'(entry_inst);
    uop_page_fault_inst         = entry_page_fault_inst;
    uop_ftq_idx                 = entry_ftq_idx;
    uop_ftq_offset              = entry_ftq_offset;
    uop_ftq_is_last             = entry_ftq_is_last;
    uop_type                    = raw_type & {5{decoded_en}};
    uop_dest_en                 = raw_dest_en & decoded_en;
    uop_src1_en                 = raw_src1_en & decoded_en;
    uop_src2_en                 = raw_src2_en & decoded_en;
    uop_is_atomic               = raw_is_atomic & decoded_en;
    uop_src1_is_pc              = raw_src1_is_pc & decoded_en;
    uop_src2_is_imm             = raw_src2_is_imm & decoded_en;
    uop_is_word                 = raw_is_word & decoded_en;
    uop_func3                   = raw_func3 & {3{decoded_en}};
    uop_func7                   = entry_inst[31:25] & {7{decoded_en}};
    uop_imm                     = raw_imm & {32{decoded_en}};
    uop_csr_idx                 = entry_inst[31:20] & {CSR_IDX_WIDTH{decoded_en}};
    uop_dest_areg               = raw_dest_areg & {AREG_IDX_WIDTH{decoded_en}};
    uop_src1_areg               = raw_src1_areg & {AREG_IDX_WIDTH{decoded_en}};
    uop_src2_areg               = raw_src2_areg & {AREG_IDX_WIDTH{decoded_en}};
    uop_illegal_inst            = raw_illegal_inst & decoded_en;
    uop_dest_fp                 = raw_dest_fp & decoded_en;
    uop_src1_fp                 = raw_src1_fp & decoded_en;
    uop_src2_fp                 = raw_src2_fp & decoded_en;
    uop_src3_en                 = raw_src3_en & decoded_en;
    uop_src3_areg               = AREG_IDX_WIDTH'(raw_src3_areg) & {AREG_IDX_WIDTH{decoded_en & raw_src3_en}};
    uop_fp_cls                  = raw_fp_cls & {3{decoded_en}};
    is_branch                   = raw_is_branch & decoded_en & entry_valid;   // needs a branch tag
  end

endmodule

`default_nettype wire
