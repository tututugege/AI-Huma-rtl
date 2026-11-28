// Ref: back-end/Ren.cpp  class Ren  (shared types; commit 2f31e8d)
`default_nettype none
// constants are consumed by other files; same pragma as the generated ttg_cfg_pkg
/* verilator lint_off UNUSEDPARAM */
package ren_pkg;
  import ttg_cfg_pkg::*;

  // InstType encodings and width: dis_pkg (inst_type_e, INST_TYPE_W), the one definition of types.h InstType
  import dis_pkg::INST_TYPE_W, dis_pkg::INST_ADD;
  // architectural registers 0..ARF_NUM-1 plus one extra RAT entry (index ARF_NUM)
  localparam int RAT_NUM = ARF_NUM + 1;

  typedef logic [PRF_IDX_WIDTH-1:0] preg_t;
  typedef logic [AREG_IDX_WIDTH-1:0] areg_t;
  // move elimination: arch_cnt[p] = number of arch_RAT entries naming p (at most RAT_NUM = 33 -> 6 bits, never overflows)
  localparam int CNT_W = $clog2(RAT_NUM + 1);
  typedef logic [CNT_W-1:0] cnt_t;
  typedef preg_t [RAT_NUM-1:0] rat_t;

  // One entry of Ren's local ROB-indexed rename log (27 bits/entry, 8 banks x ROB_LINE_NUM rows).
  typedef struct packed {
    logic  dest_en;
    logic  dest_fp;
    areg_t dest_areg;
    preg_t dest_preg;
    preg_t old_dest_preg;
    logic  me_elim;
  } ren_log_entry_t;

  // one decoded instruction as held in the Rename pipeline register (DecRenIO::DecRenInst; only fields with a
  // consumer: tma/dbg and the always-zero expect_mask/cplt_mask are dropped)
  typedef struct packed {
    logic [XLEN_BITS-1:0] diag_val;
    areg_t dest_areg;
    areg_t src1_areg;
    areg_t src2_areg;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic ftq_is_last;
    logic [INST_TYPE_W-1:0] inst_type;
    logic dest_en;
    logic src1_en;
    logic src2_en;
    logic is_atomic;
    logic src1_is_pc;
    logic src2_is_imm;
    logic is_word;
    logic [2:0] func3;
    logic [6:0] func7;
    logic [31:0] imm;
    logic [CSR_IDX_WIDTH-1:0] csr_idx;
    logic page_fault_inst;
    logic pf_inst_hi;
    logic illegal_inst;
    logic dest_fp;           // F/D: the destination / sources live in the FP register file (tags FP_TAG_BASE+)
    logic src1_fp;
    logic src2_fp;
    logic src3_en;           // third FP source (fused multiply-add), always FP
    areg_t src3_areg;
    logic [2:0] fp_cls;
  } ren_inst_t;

  // renamed instruction sent to Dispatch: only the fields Dispatch/ROB/IQs consume (src2_areg, src*_busy, and
  // the masks are not consumed downstream); meaningful only while ren2dis_valid.
  // src1_areg IS consumed: Dispatch -> Rob keeps it and Rob::commit_extra hands it to the front end (RET detection),
  // found only at BackTop integration (docs/modules/back_top.md, finding I-1).
  typedef struct packed {
    logic [XLEN_BITS-1:0] diag_val;
    areg_t dest_areg;
    areg_t src1_areg;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic ftq_is_last;
    logic [INST_TYPE_W-1:0] inst_type;
    logic dest_en;
    logic src1_en;
    logic src2_en;
    logic is_atomic;
    logic src1_is_pc;
    logic src2_is_imm;
    logic is_word;
    logic [2:0] func3;
    logic [6:0] func7;
    logic [31:0] imm;
    logic [CSR_IDX_WIDTH-1:0] csr_idx;
    logic page_fault_inst;
    logic pf_inst_hi;
    logic illegal_inst;
    preg_t dest_preg;
    preg_t src1_preg;
    preg_t src2_preg;
    logic me_elim;     // move elimination: dest_preg is src1_preg's register, no uop is issued
    logic dest_fp;
    logic src1_fp;
    logic src2_fp;
    logic src3_en;
    preg_t src3_preg;
    logic [2:0] fp_cls;
  } ren_out_uop_t;

  // the part of a ROB commit entry Ren reads (rename fields live in Ren's local ren_log)
  typedef struct packed {
    logic valid;
    logic page_fault_inst;
    logic page_fault_load;
    logic page_fault_store;
    logic illegal_inst;
    logic [INST_TYPE_W-1:0] inst_type;
  } ren_commit_t;

  // `addi rd, rs, 0` with rd and rs real registers (back-end/include/util.h is_move_shape)
  function automatic logic ren_is_move_shape(input logic [INST_TYPE_W-1:0] t, input logic src2_is_imm,
                                             input logic is_word, input logic [2:0] func3,
                                             input logic [31:0] imm, input logic src1_en,
                                             input logic src1_is_pc, input areg_t src1_areg, input logic dest_en,
                                             input areg_t dest_areg);
    return (t == INST_ADD) && src2_is_imm && !is_word && (func3 == 3'd0) && (imm == 32'd0) && src1_en &&
           !src1_is_pc &&
           (src1_areg != areg_t'(0)) && dest_en && (dest_areg != areg_t'(0));
  endfunction

  // ---- F/D rename state: 32 architectural FP registers (no x0), tags FP_TAG_BASE .. +FPRF_NUM-1,
  // a free list of FPRF_NUM - FP_ARF_NUM registers kept as a ring of FPRF_NUM slots (not a power of two) ----
  localparam int FPN = FPRF_NUM;
  localparam int FP_PTR_W = $clog2(FPN);
  typedef logic [FP_PTR_W-1:0] fp_ptr_t;
  typedef preg_t [FP_ARF_NUM-1:0] fp_rat_t;

  // ring pointer arithmetic modulo FPRF_NUM (p + n, n <= FPRF_NUM)
  function automatic fp_ptr_t fp_ptr_add(input fp_ptr_t p, input fp_ptr_t n);
    logic [FP_PTR_W:0] sum;
    sum = {1'b0, p} + {1'b0, n};
    return (sum >= (FP_PTR_W+1)'(FPN)) ? fp_ptr_t'(sum - (FP_PTR_W+1)'(FPN)) : fp_ptr_t'(sum);
  endfunction

endpackage

`default_nettype wire
