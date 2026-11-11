// Ref: front-end/BPU/target_predictor/BTB_top.h  (index / tag hashes, entry formats of the BTB and the ITT)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Pure functions of the BTB: all arithmetic is 32-bit unsigned like the C++ (the hash input is the BANK pc = pc>>3).
// The target cache / BHT of the zero-bubble design are replaced by the history-indexed ITT.
package bpu_btb_pkg;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;

  localparam logic [31:0] SALT_BTB_IDX = 32'h9e3779b9;

  typedef struct packed {
    logic [2:0]         useful;
    logic               valid;
    logic [B_TAG_W-1:0] tag;
    logic [XLEN_BITS-1:0]        bta;
  } btb_ent_t;

  function automatic logic [B_IDX_W-1:0] btb_idx_of(input logic [XLEN_BITS-1:0] bank_pc);
    return B_IDX_W'(hash_fold(32'(bank_pc >> 2), B_IDX_W, SALT_BTB_IDX));   // low 32 bits of the word address
  endfunction

  function automatic logic [B_TAG_W-1:0] btb_tag_of(input logic [XLEN_BITS-1:0] bank_pc);
    return B_TAG_W'((bank_pc >> 2) >> B_IDX_W);
  endfunction

  // useful_next_state_comb: saturating 0..7
  function automatic logic [2:0] useful_next_of(input logic [2:0] cur, input logic correct);
    if (correct) return (cur == 3'd7) ? 3'd7 : cur + 3'd1;
    return (cur == 3'd0) ? 3'd0 : cur - 3'd1;
  endfunction

endpackage

`default_nettype wire
