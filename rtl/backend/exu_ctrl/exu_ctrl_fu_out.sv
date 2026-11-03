// Ref: back-end/Exu/Exu.cpp  Exu::comb_exu2fu_dispatch (out.exu2fu->entry[i].{en, consume, inst})
`default_nettype none

// Operands handed to the FUs, grouped by FU kind. Single-cycle FUs get only their compute operands;
// multi-cycle FUs (MUL/DIV/FP) also get the pass-through fields they carry themselves.
module exu_ctrl_fu_out
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic [N_FU-1:0] fu_en,
  input  xc_inst_t        fu_inst [N_FU],
  input  logic [N_FU-1:0] consume,
  output logic exu2fu_alu_en [ALU_NUM],
  output logic [XC_OP_W-1:0] exu2fu_alu_op [ALU_NUM],
  output logic [2:0] exu2fu_alu_func3 [ALU_NUM],
  output logic [6:0] exu2fu_alu_func7 [ALU_NUM],
  output logic exu2fu_alu_src1_is_pc [ALU_NUM],
  output logic exu2fu_alu_src2_is_imm [ALU_NUM],
  output logic [31:0] exu2fu_alu_pc [ALU_NUM],
  output logic [31:0] exu2fu_alu_imm [ALU_NUM],
  output logic [31:0] exu2fu_alu_src1_rdata [ALU_NUM],
  output logic [31:0] exu2fu_alu_src2_rdata [ALU_NUM],
  output logic exu2fu_bru_en [BRU_NUM],
  output logic [XC_OP_W-1:0] exu2fu_bru_op [BRU_NUM],
  output logic [2:0] exu2fu_bru_func3 [BRU_NUM],
  output logic exu2fu_bru_src1_en [BRU_NUM],
  output logic [31:0] exu2fu_bru_src1_rdata [BRU_NUM],
  output logic [31:0] exu2fu_bru_src2_rdata [BRU_NUM],
  output logic [31:0] exu2fu_bru_pc [BRU_NUM],
  output logic [31:0] exu2fu_bru_imm [BRU_NUM],
  output logic exu2fu_bru_ftq_pred_taken [BRU_NUM],
  output logic [31:0] exu2fu_bru_ftq_next_pc [BRU_NUM],
  output logic exu2fu_agu_en [LSU_AGU_COUNT],
  output logic [31:0] exu2fu_agu_src1_rdata [LSU_AGU_COUNT],
  output logic [31:0] exu2fu_agu_imm [LSU_AGU_COUNT],
  output logic exu2fu_sdu_en [LSU_SDU_COUNT],
  output logic exu2fu_sdu_is_atomic [LSU_SDU_COUNT],
  output logic [6:0] exu2fu_sdu_func7 [LSU_SDU_COUNT],
  output logic [31:0] exu2fu_sdu_src1_rdata [LSU_SDU_COUNT],
  output logic [31:0] exu2fu_sdu_src2_rdata [LSU_SDU_COUNT],
  output logic exu2fu_mc_en [N_MC],
  output logic exu2fu_mc_consume [N_MC],
  output logic [2:0] exu2fu_mc_func3 [N_MC],
  output logic [6:0] exu2fu_mc_func7 [N_MC],
  output logic [XC_OP_W-1:0] exu2fu_mc_op [N_MC],
  output logic [31:0] exu2fu_mc_imm [N_MC],
  output logic [31:0] exu2fu_mc_src1_rdata [N_MC],
  output logic [31:0] exu2fu_mc_src2_rdata [N_MC],
  output logic [PRF_IDX_WIDTH-1:0] exu2fu_mc_dest_preg [N_MC],
  output logic exu2fu_mc_dest_en [N_MC],
  output logic [BR_MASK_WIDTH-1:0] exu2fu_mc_br_mask [N_MC],
  output logic [ROB_IDX_WIDTH-1:0] exu2fu_mc_rob_idx [N_MC]
);

  for (genvar i = 0; i < ALU_NUM; i++) begin : g_alu
    localparam int FU = xc_kind_fu(XC_K_ALU, i);
    assign exu2fu_alu_en[i]          = fu_en[FU];
    assign exu2fu_alu_op[i]          = fu_inst[FU].op;
    assign exu2fu_alu_func3[i]       = fu_inst[FU].func3;
    assign exu2fu_alu_func7[i]       = fu_inst[FU].func7;
    assign exu2fu_alu_src1_is_pc[i]  = fu_inst[FU].src1_is_pc;
    assign exu2fu_alu_src2_is_imm[i] = fu_inst[FU].src2_is_imm;
    assign exu2fu_alu_pc[i]          = fu_inst[FU].pc;
    assign exu2fu_alu_imm[i]         = fu_inst[FU].imm;
    assign exu2fu_alu_src1_rdata[i]  = fu_inst[FU].src1_rdata;
    assign exu2fu_alu_src2_rdata[i]  = fu_inst[FU].src2_rdata;
  end

  for (genvar i = 0; i < BRU_NUM; i++) begin : g_bru
    localparam int FU = xc_kind_fu(XC_K_BR, i);
    assign exu2fu_bru_en[i]             = fu_en[FU];
    assign exu2fu_bru_op[i]             = fu_inst[FU].op;
    assign exu2fu_bru_func3[i]          = fu_inst[FU].func3;
    assign exu2fu_bru_src1_en[i]        = fu_inst[FU].src1_en;
    assign exu2fu_bru_src1_rdata[i]     = fu_inst[FU].src1_rdata;
    assign exu2fu_bru_src2_rdata[i]     = fu_inst[FU].src2_rdata;
    assign exu2fu_bru_pc[i]             = fu_inst[FU].pc;
    assign exu2fu_bru_imm[i]            = fu_inst[FU].imm;
    assign exu2fu_bru_ftq_pred_taken[i] = fu_inst[FU].ftq_pred_taken;
    assign exu2fu_bru_ftq_next_pc[i]    = fu_inst[FU].ftq_next_pc;
  end

  for (genvar i = 0; i < N_AGU; i++) begin : g_agu_out
    localparam int FU = xc_agu_fu(i);
    assign exu2fu_agu_en[i]         = fu_en[FU];
    assign exu2fu_agu_src1_rdata[i] = fu_inst[FU].src1_rdata;
    assign exu2fu_agu_imm[i]        = fu_inst[FU].imm;
  end

  for (genvar i = 0; i < N_SDU; i++) begin : g_sdu_out
    localparam int FU = xc_kind_fu(XC_K_STD, i);
    assign exu2fu_sdu_en[i]         = fu_en[FU];
    assign exu2fu_sdu_is_atomic[i]  = fu_inst[FU].is_atomic;
    assign exu2fu_sdu_func7[i]      = fu_inst[FU].func7;
    assign exu2fu_sdu_src1_rdata[i] = fu_inst[FU].src1_rdata;
    assign exu2fu_sdu_src2_rdata[i] = fu_inst[FU].src2_rdata;
  end

  for (genvar i = 0; i < N_MC; i++) begin : g_mc_out
    localparam int FU = xc_mc_fu(i);
    assign exu2fu_mc_en[i]         = fu_en[FU];
    assign exu2fu_mc_consume[i]    = consume[FU];
    assign exu2fu_mc_func3[i]      = fu_inst[FU].func3;
    assign exu2fu_mc_func7[i]      = fu_inst[FU].func7;
    assign exu2fu_mc_op[i]         = fu_inst[FU].op;
    assign exu2fu_mc_imm[i]        = fu_inst[FU].imm;
    assign exu2fu_mc_src1_rdata[i] = fu_inst[FU].src1_rdata;
    assign exu2fu_mc_src2_rdata[i] = fu_inst[FU].src2_rdata;
    assign exu2fu_mc_dest_preg[i]  = fu_inst[FU].dest_preg;
    assign exu2fu_mc_dest_en[i]    = fu_inst[FU].dest_en;
    assign exu2fu_mc_br_mask[i]    = fu_inst[FU].br_mask;
    assign exu2fu_mc_rob_idx[i]    = fu_inst[FU].rob_idx;
  end

endmodule

`default_nettype wire
