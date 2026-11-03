// Ref: back-end/Ren.cpp  class Ren  (shared types; commit 2f31e8d)
`default_nettype none
// constants are consumed by other files; same pragma as the generated ttg_cfg_pkg
/* verilator lint_off UNUSEDPARAM */
package ren_pkg;
  import ttg_cfg_pkg::*;

  // back-end/include/types.h: INST_TYPE_COUNT = 20 -> bit_width_for_count = 5
  localparam int INST_TYPE_WIDTH = 5;
  // back-end/include/base_types.h
  localparam int ROB_CPLT_MASK_WIDTH = 3;
  // architectural registers 0..ARF_NUM-1 plus one extra RAT entry (index ARF_NUM)
  localparam int RAT_NUM = ARF_NUM + 1;
  // InstType enum values used by Ren (types.h)
  localparam logic [INST_TYPE_WIDTH-1:0] ITYPE_JALR = INST_TYPE_WIDTH'(2);
  localparam logic [INST_TYPE_WIDTH-1:0] ITYPE_BR = INST_TYPE_WIDTH'(4);
  localparam logic [INST_TYPE_WIDTH-1:0] ITYPE_ECALL = INST_TYPE_WIDTH'(9);

  typedef logic [PRF_IDX_WIDTH-1:0] preg_t;
  typedef logic [AREG_IDX_WIDTH-1:0] areg_t;
  typedef logic [BR_TAG_WIDTH-1:0] br_tag_t;
  typedef logic [BR_MASK_WIDTH-1:0] br_mask_t;
  typedef preg_t [RAT_NUM-1:0] rat_t;

  // one decoded instruction as held in the Rename pipeline register (DecRenIO::DecRenInst, no tma/dbg)
  typedef struct packed {
    logic [31:0] diag_val;
    areg_t dest_areg;
    areg_t src1_areg;
    areg_t src2_areg;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic ftq_is_last;
    logic [INST_TYPE_WIDTH-1:0] inst_type;
    logic dest_en;
    logic src1_en;
    logic src2_en;
    logic is_atomic;
    logic src1_is_pc;
    logic src2_is_imm;
    logic [2:0] func3;
    logic [6:0] func7;
    logic [31:0] imm;
    br_tag_t br_id;
    br_mask_t br_mask;
    logic [CSR_IDX_WIDTH-1:0] csr_idx;
    logic [ROB_CPLT_MASK_WIDTH-1:0] expect_mask;
    logic [ROB_CPLT_MASK_WIDTH-1:0] cplt_mask;
    logic page_fault_inst;
    logic illegal_inst;
  } ren_inst_t;

  // renamed instruction sent to Dispatch (RenDisIO::RenDisInst; src*_busy are always 0 in Ren)
  typedef struct packed {
    ren_inst_t inst;
    preg_t dest_preg;
    preg_t src1_preg;
    preg_t src2_preg;
    preg_t old_dest_preg;
  } ren_out_uop_t;

  // the part of a ROB commit entry Ren reads (RobCommitIO::RobCommitEntry)
  typedef struct packed {
    logic valid;
    logic dest_en;
    areg_t dest_areg;
    preg_t dest_preg;
    preg_t old_dest_preg;
    logic page_fault_inst;
    logic page_fault_load;
    logic page_fault_store;
    logic illegal_inst;
    logic [INST_TYPE_WIDTH-1:0] inst_type;
  } ren_commit_t;

  // reset value of a RAT: arch/spec reg i -> preg i (Ren::init)
  function automatic rat_t rat_identity();
    rat_t r;
    for (int i = 0; i < RAT_NUM; i++) r[i] = preg_t'(i);
    return r;
  endfunction

  // reset value of the free list: pregs RAT_NUM..PRF_NUM-1 in order, rest 0 (Ren::init)
  function automatic logic [PRF_NUM-1:0][PRF_IDX_WIDTH-1:0] free_list_init();
    logic [PRF_NUM-1:0][PRF_IDX_WIDTH-1:0] l;
    l = '0;
    for (int i = 0; i < PRF_NUM - RAT_NUM; i++) l[i] = preg_t'(RAT_NUM + i);
    return l;
  endfunction

endpackage

`default_nettype wire
