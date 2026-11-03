// Ref: front-end/BPU/target_predictor/BTB_top.h  (index/tag hashes, BHT update, entry formats)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Pure functions of the BTB: all arithmetic is 32-bit unsigned like the C++ (the hash input is the BANK pc = pc>>3).
package bpu_btb_pkg;
  import bpu_pkg::*;

  localparam logic [31:0] SALT_BTB_IDX = 32'h9e3779b9;
  localparam logic [31:0] SALT_BHT_IDX = 32'h6a5d39e1;
  localparam logic [31:0] SALT_TC_IDX  = 32'h51ed270b;
  localparam logic [31:0] SALT_TC_TAG  = 32'h3c6ef372;
  localparam logic [31:0] SALT_BHT_UPD = 32'h9e3779b9;
  localparam logic [2:0]  TC_MODE_BIAS = 3'd3;
  localparam logic [2:0]  TC_MODE_INIT = 3'd2;
  localparam logic [2:0]  TC_MODE_MAX  = 3'd6;

  typedef struct packed {
    logic [2:0]         useful;
    logic               valid;
    logic [B_TAG_W-1:0] tag;
    logic [31:0]        bta;
  } btb_ent_t;

  typedef struct packed {
    logic [2:0]         useful;
    logic               valid;
    logic [TC_TAG_W-1:0] tag;
    logic [31:0]        target;
  } tc_ent_t;

  function automatic logic [B_IDX_W-1:0] btb_idx_of(input logic [31:0] bank_pc);
    return B_IDX_W'(hash_fold(bank_pc >> 2, B_IDX_W, SALT_BTB_IDX));
  endfunction

  function automatic logic [B_TAG_W-1:0] btb_tag_of(input logic [31:0] bank_pc);
    return B_TAG_W'((bank_pc >> 2) >> B_IDX_W);
  endfunction

  function automatic logic [BHT_W-1:0] bht_idx_of(input logic [31:0] bank_pc);
    return BHT_W'(hash_fold(bank_pc >> 2, BHT_W, SALT_BHT_IDX));
  endfunction

  // tc_get_idx_comb: the BHT value is the 8-bit stored history
  function automatic logic [TC_IDX_W-1:0] tc_idx_of(input logic [31:0] bank_pc, input logic [BHT_DW-1:0] bht);
    logic [31:0] b;
    logic [31:0] hist_mix;
    b        = {24'd0, bht};
    hist_mix = b ^ (b >> 7) ^ (b >> 13) ^ (b << 9);
    return TC_IDX_W'(hash_fold((bank_pc >> 2) ^ hist_mix ^ (b >> 19), TC_IDX_W, SALT_TC_IDX));
  endfunction

  function automatic logic [TC_TAG_W-1:0] tc_tag_of(input logic [31:0] bank_pc);
    return TC_TAG_W'(hash_fold(bank_pc >> 2, TC_TAG_W, SALT_TC_TAG));
  endfunction

  // bht_next_state_comb (ENABLE_TC_TARGET_SIGNATURE=1), truncated to the 8-bit storage type
  function automatic logic [BHT_DW-1:0] bht_next_of(input logic [BHT_DW-1:0] cur, input logic [2:0] br_type,
                                                    input logic dir, input logic [31:0] target);
    logic [31:0] c;
    logic [31:0] t;
    c = {24'd0, cur};
    t = target >> 2;
    if (br_type == BR_IDIRECT) return BHT_DW'((c ^ (c << 5) ^ (c >> 2)) ^ (t ^ (t >> 11) ^ (t >> 19)) ^ SALT_BHT_UPD);
    return BHT_DW'((c << 1) | {31'd0, dir});
  endfunction

  // useful_next_state_comb: saturating 0..7
  function automatic logic [2:0] useful_next_of(input logic [2:0] cur, input logic correct);
    if (correct) return (cur == 3'd7) ? 3'd7 : cur + 3'd1;
    return (cur == 3'd0) ? 3'd0 : cur - 3'd1;
  endfunction

endpackage

`default_nettype wire
