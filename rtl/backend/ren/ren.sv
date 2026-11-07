// Ref: back-end/Ren.cpp  class Ren  (commit 2f31e8d)
`default_nettype none

// Port adapter only: flat spec ports <-> packed structs of ren_core.
module ren
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic [DECODE_WIDTH-1:0] dec2ren_valid,
  input  logic [31:0] dec2ren_uop_diag_val [DECODE_WIDTH],
  input  logic [AREG_IDX_WIDTH-1:0] dec2ren_uop_dest_areg [DECODE_WIDTH],
  input  logic [AREG_IDX_WIDTH-1:0] dec2ren_uop_src1_areg [DECODE_WIDTH],
  input  logic [AREG_IDX_WIDTH-1:0] dec2ren_uop_src2_areg [DECODE_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0] dec2ren_uop_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] dec2ren_uop_ftq_offset [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_ftq_is_last,
  input  logic [INST_TYPE_WIDTH-1:0] dec2ren_uop_type [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_dest_en,
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_src1_en,
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_src2_en,
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_is_atomic,
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_src1_is_pc,
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_src2_is_imm,
  input  logic [2:0] dec2ren_uop_func3 [DECODE_WIDTH],
  input  logic [6:0] dec2ren_uop_func7 [DECODE_WIDTH],
  input  logic [31:0] dec2ren_uop_imm [DECODE_WIDTH],
  input  logic [BR_TAG_WIDTH-1:0] dec2ren_uop_br_id [DECODE_WIDTH],
  input  logic [BR_MASK_WIDTH-1:0] dec2ren_uop_br_mask [DECODE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] dec2ren_uop_csr_idx [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_page_fault_inst,
  input  logic [DECODE_WIDTH-1:0] dec2ren_uop_illegal_inst,
  input  logic dec_bcast_mispred,
  input  logic [BR_TAG_WIDTH-1:0] dec_bcast_br_id,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_clear_mask,
  input  logic dis2ren_ready,
  input  logic rob_bcast_flush,
  input  logic rob_bcast_interrupt,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid,
  input  logic [AREG_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_dest_preg [COMMIT_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_old_dest_preg [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_dest_en,
  input  logic [INST_TYPE_WIDTH-1:0] rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_me_elim,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_inst,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_load,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_store,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_illegal_inst,
  output logic ren2dec_ready,
  output logic [DECODE_WIDTH-1:0] ren2dis_valid,
  output logic [31:0] ren2dis_uop_diag_val [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0] ren2dis_uop_dest_areg [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0] ren2dis_uop_src1_areg [DECODE_WIDTH],
  output logic [FTQ_IDX_WIDTH-1:0] ren2dis_uop_ftq_idx [DECODE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] ren2dis_uop_ftq_offset [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_ftq_is_last,
  output logic [INST_TYPE_WIDTH-1:0] ren2dis_uop_type [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_dest_en,
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_src1_en,
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_src2_en,
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_is_atomic,
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_src1_is_pc,
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_src2_is_imm,
  output logic [2:0] ren2dis_uop_func3 [DECODE_WIDTH],
  output logic [6:0] ren2dis_uop_func7 [DECODE_WIDTH],
  output logic [31:0] ren2dis_uop_imm [DECODE_WIDTH],
  output logic [BR_TAG_WIDTH-1:0] ren2dis_uop_br_id [DECODE_WIDTH],
  output logic [BR_MASK_WIDTH-1:0] ren2dis_uop_br_mask [DECODE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0] ren2dis_uop_csr_idx [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_page_fault_inst,
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_illegal_inst,
  output logic [PRF_IDX_WIDTH-1:0] ren2dis_uop_dest_preg [DECODE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] ren2dis_uop_src1_preg [DECODE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] ren2dis_uop_src2_preg [DECODE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] ren2dis_uop_old_dest_preg [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] ren2dis_uop_me_elim
);

  logic [DECODE_WIDTH-1:0] dec_valid;
  ren_inst_t dec_uop [DECODE_WIDTH];
  logic [DECODE_WIDTH-1:0] out_valid;
  ren_out_uop_t out_uop [DECODE_WIDTH];
  ren_commit_t commit [COMMIT_WIDTH];

  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_dec
    assign dec_valid[i] = dec2ren_valid[i];
    assign dec_uop[i] = '{
diag_val: dec2ren_uop_diag_val[i],
                          dest_areg: dec2ren_uop_dest_areg[i],
                          src1_areg: dec2ren_uop_src1_areg[i],
                          src2_areg: dec2ren_uop_src2_areg[i],
                          ftq_idx: dec2ren_uop_ftq_idx[i],
                          ftq_offset: dec2ren_uop_ftq_offset[i],
                          ftq_is_last: dec2ren_uop_ftq_is_last[i],
                          inst_type: dec2ren_uop_type[i],
                          dest_en: dec2ren_uop_dest_en[i],
                          src1_en: dec2ren_uop_src1_en[i],
                          src2_en: dec2ren_uop_src2_en[i],
                          is_atomic: dec2ren_uop_is_atomic[i],
                          src1_is_pc: dec2ren_uop_src1_is_pc[i],
                          src2_is_imm: dec2ren_uop_src2_is_imm[i],
                          func3: dec2ren_uop_func3[i],
                          func7: dec2ren_uop_func7[i],
                          imm: dec2ren_uop_imm[i],
                          br_id: dec2ren_uop_br_id[i],
                          br_mask: dec2ren_uop_br_mask[i],
                          csr_idx: dec2ren_uop_csr_idx[i],
                          page_fault_inst: dec2ren_uop_page_fault_inst[i],
                          illegal_inst: dec2ren_uop_illegal_inst[i]};
    assign ren2dis_valid[i] = out_valid[i];
    assign ren2dis_uop_diag_val[i] = out_uop[i].diag_val;
    assign ren2dis_uop_dest_areg[i] = out_uop[i].dest_areg;
    assign ren2dis_uop_src1_areg[i] = out_uop[i].src1_areg;
    assign ren2dis_uop_ftq_idx[i] = out_uop[i].ftq_idx;
    assign ren2dis_uop_ftq_offset[i] = out_uop[i].ftq_offset;
    assign ren2dis_uop_ftq_is_last[i] = out_uop[i].ftq_is_last;
    assign ren2dis_uop_type[i] = out_uop[i].inst_type;
    assign ren2dis_uop_dest_en[i] = out_uop[i].dest_en;
    assign ren2dis_uop_src1_en[i] = out_uop[i].src1_en;
    assign ren2dis_uop_src2_en[i] = out_uop[i].src2_en;
    assign ren2dis_uop_is_atomic[i] = out_uop[i].is_atomic;
    assign ren2dis_uop_src1_is_pc[i] = out_uop[i].src1_is_pc;
    assign ren2dis_uop_src2_is_imm[i] = out_uop[i].src2_is_imm;
    assign ren2dis_uop_func3[i] = out_uop[i].func3;
    assign ren2dis_uop_func7[i] = out_uop[i].func7;
    assign ren2dis_uop_imm[i] = out_uop[i].imm;
    assign ren2dis_uop_br_id[i] = out_uop[i].br_id;
    assign ren2dis_uop_br_mask[i] = out_uop[i].br_mask;
    assign ren2dis_uop_csr_idx[i] = out_uop[i].csr_idx;
    assign ren2dis_uop_page_fault_inst[i] = out_uop[i].page_fault_inst;
    assign ren2dis_uop_illegal_inst[i] = out_uop[i].illegal_inst;
    assign ren2dis_uop_dest_preg[i] = out_uop[i].dest_preg;
    assign ren2dis_uop_src1_preg[i] = out_uop[i].src1_preg;
    assign ren2dis_uop_src2_preg[i] = out_uop[i].src2_preg;
    assign ren2dis_uop_old_dest_preg[i] = out_uop[i].old_dest_preg;
    assign ren2dis_uop_me_elim[i] = out_uop[i].me_elim;
  end

  for (genvar k = 0; k < COMMIT_WIDTH; k++) begin : g_commit
    assign commit[k] = '{valid: rob_commit_commit_entry_valid[k],
dest_areg: rob_commit_commit_entry_uop_dest_areg[k],
                         dest_preg: rob_commit_commit_entry_uop_dest_preg[k],
                         old_dest_preg: rob_commit_commit_entry_uop_old_dest_preg[k],
                         dest_en: rob_commit_commit_entry_uop_dest_en[k],
                         inst_type: rob_commit_commit_entry_uop_type[k],
                         me_elim: rob_commit_commit_entry_uop_me_elim[k],
                         page_fault_inst: rob_commit_commit_entry_uop_page_fault_inst[k],
                         page_fault_load: rob_commit_commit_entry_uop_page_fault_load[k],
                         page_fault_store: rob_commit_commit_entry_uop_page_fault_store[k],
                         illegal_inst: rob_commit_commit_entry_uop_illegal_inst[k]};
  end

  ren_core u_core (
    .clk(clk), .rst_n(rst_n), .dec_valid(dec_valid), .dec_uop(dec_uop),
    .dec_mispred(dec_bcast_mispred), .dec_br_id(dec_bcast_br_id), .dec_clear_mask(dec_bcast_clear_mask),
    .dis_ready(dis2ren_ready), .rob_flush(rob_bcast_flush), .rob_interrupt(rob_bcast_interrupt),
    .commit(commit), .ren2dec_ready(ren2dec_ready), .ren2dis_valid(out_valid), .ren2dis_uop(out_uop)
  );

endmodule

`default_nettype wire
