// Ref: front-end/BPU/target_predictor/BTB_top.h  BTB_TOP::btb_comb (update part)
`default_nettype none

// Update decision of one BTB bank (one update per cycle, from the update queue).  Reads are done by the bank: this
// module gets the START-of-cycle contents and returns the write requests (all arrays are written at the clock edge).
// Two-step read like the C++: BHT first, then the TC sets indexed by the old / new BHT value.
module bpu_btb_upd import bpu_pkg::*; import bpu_btb_pkg::*; (
  input  logic                upd_valid,
  input  logic [31:0]         upd_pc,           // bank pc
  input  logic [31:0]         upd_actual_addr,
  input  logic [2:0]          upd_br_type,
  input  logic                upd_actual_dir,
  input  btb_ent_t            btb_set    [B_WAYS],     // set at btb_idx
  input  logic [BHT_DW-1:0]   bht_old,                 // bht[bht_idx]
  input  tc_ent_t             tc_set     [TC_WAYS],    // tc at tc_write_idx
  input  tc_ent_t             tc_pred_set [TC_WAYS],   // tc at tc_pred_idx
  input  tc_ent_t             tc_pre_set [TC_WAYS],    // tc_pre at tc_pred_idx
  input  logic [2:0]          tc_mode_old,             // tc_mode[bht_idx]
  output logic [B_IDX_W-1:0]  btb_idx,
  output logic [BHT_W-1:0]    bht_idx,
  output logic [TC_IDX_W-1:0] tc_pred_idx,
  output logic [TC_IDX_W-1:0] tc_write_idx,
  // write requests
  output logic                bht_we,
  output logic [BHT_DW-1:0]   bht_wdata,
  output logic                btb_we,
  output logic [1:0]          btb_way,
  output btb_ent_t            btb_wdata,
  output logic                tc_we,
  output logic [0:0]          tc_way,
  output tc_ent_t             tc_wdata,
  output logic                tc_pre_we,
  output logic [0:0]          tc_pre_way,
  output tc_ent_t             tc_pre_wdata,
  output logic                tc_mode_we,
  output logic [2:0]          tc_mode_wdata
);

  logic [BHT_DW-1:0]   bht_next;
  logic                is_idirect_taken;
  logic                writes_btb;
  logic [B_TAG_W-1:0]  tag;
  logic [TC_TAG_W-1:0] tc_tag;
  // BTB way choice
  logic [B_WAYS-1:0]   hit_way;
  logic                hit;
  logic [1:0]          hit_idx;
  logic [1:0]          victim;
  logic [1:0]          write_way;
  logic                correct_pred;
  // TC choice (shared structure for tc and tc_pre)
  logic                tc_hit;
  logic [0:0]          tc_hit_way;
  logic [0:0]          tc_victim;
  logic                tc_correct;
  logic                tc_pre_hit;
  logic [0:0]          tc_pre_hit_way;
  logic [0:0]          tc_pre_victim;
  logic                tc_pre_correct;
  logic                tc_pred_correct;

  // Ref: btb_post_read_req_comb (indices) and the BTB part of btb_comb
  always_comb begin
    bht_next         = bht_next_of(bht_old, upd_br_type, upd_actual_dir, upd_actual_addr);
    btb_idx          = btb_idx_of(upd_pc);
    bht_idx          = bht_idx_of(upd_pc);
    tag              = btb_tag_of(upd_pc);
    tc_tag           = tc_tag_of(upd_pc);
    tc_pred_idx      = tc_idx_of(upd_pc, bht_old);
    tc_write_idx     = tc_idx_of(upd_pc, bht_next);
    is_idirect_taken = upd_actual_dir && (upd_br_type == BR_IDIRECT);
    writes_btb       = (upd_br_type == BR_DIRECT) || (upd_br_type == BR_CALL) || (upd_br_type == BR_RET) ||
                       (upd_br_type == BR_JAL) || (upd_br_type == BR_IDIRECT);   // ENABLE_INDIRECT_BTB_TRAIN
    for (int w = 0; w < B_WAYS; w++) hit_way[w] = btb_set[w].valid && (btb_set[w].tag == tag);
    hit     = |hit_way;
    hit_idx = hit_way[0] ? 2'd0 : hit_way[1] ? 2'd1 : hit_way[2] ? 2'd2 : 2'd3;
    // victim: first invalid way, else the way with the smallest useful (lowest index on ties)
    victim = 2'd0;
    for (int w = B_WAYS - 1; w >= 0; w--) if (btb_set[w].useful <= btb_set[victim].useful) victim = 2'(w);
    for (int w = B_WAYS - 1; w >= 0; w--) if (!btb_set[w].valid) victim = 2'(w);
    write_way    = hit ? hit_idx : victim;
    correct_pred = hit && (btb_set[write_way].bta == upd_actual_addr);
  end

  always_comb begin
    bht_we    = upd_valid && (upd_br_type != BR_NONCTL);
    bht_wdata = bht_next;
    btb_we    = upd_valid && upd_actual_dir && writes_btb;
    btb_way   = write_way;
    btb_wdata.valid  = 1'b1;
    btb_wdata.tag    = tag;
    btb_wdata.bta    = upd_actual_addr;
    btb_wdata.useful = (upd_br_type == BR_IDIRECT) ? 3'd0 :
                       hit ? useful_next_of(btb_set[write_way].useful, correct_pred) : 3'd1;
  end

  // TC / TC-pre: update only for taken indirect jumps
  always_comb begin
    tc_hit = 1'b0; tc_hit_way = 1'b0; tc_pre_hit = 1'b0; tc_pre_hit_way = 1'b0;
    for (int w = TC_WAYS - 1; w >= 0; w--) begin
      if (tc_set[w].valid && tc_set[w].tag == tc_tag)         begin tc_hit = 1'b1;     tc_hit_way = 1'(w); end
      if (tc_pre_set[w].valid && tc_pre_set[w].tag == tc_tag) begin tc_pre_hit = 1'b1; tc_pre_hit_way = 1'(w); end
    end
    // victim: first invalid way, else the smaller useful (way 1 only if strictly smaller)
    tc_victim     = !tc_set[0].valid ? 1'b0 : !tc_set[1].valid ? 1'b1 : (tc_set[1].useful < tc_set[0].useful);
    tc_pre_victim = !tc_pre_set[0].valid ? 1'b0 : !tc_pre_set[1].valid ? 1'b1 :
                    (tc_pre_set[1].useful < tc_pre_set[0].useful);
    tc_correct      = tc_hit && (tc_set[tc_hit ? tc_hit_way : tc_victim].target == upd_actual_addr);
    tc_pre_correct  = tc_pre_hit && (tc_pre_set[tc_pre_hit_way].target == upd_actual_addr);
    tc_pred_correct = 1'b0;
    for (int w = TC_WAYS - 1; w >= 0; w--)
      if (tc_pred_set[w].valid && tc_pred_set[w].tag == tc_tag)
        tc_pred_correct = (tc_pred_set[w].target == upd_actual_addr);
  end

  always_comb begin
    tc_we         = upd_valid && is_idirect_taken;
    tc_way        = tc_hit ? tc_hit_way : tc_victim;
    tc_wdata.valid  = 1'b1;
    tc_wdata.tag    = tc_tag;
    tc_wdata.target = upd_actual_addr;
    tc_wdata.useful = tc_hit ? useful_next_of(tc_set[tc_way].useful, tc_correct) : 3'd1;   // INDIRECT_TC_INIT_USEFUL
    tc_pre_we     = upd_valid && is_idirect_taken;
    tc_pre_way    = tc_pre_hit ? tc_pre_hit_way : tc_pre_victim;
    tc_pre_wdata.valid  = 1'b1;
    tc_pre_wdata.tag    = tc_tag;
    tc_pre_wdata.target = upd_actual_addr;
    tc_pre_wdata.useful = tc_pre_hit ? useful_next_of(tc_pre_set[tc_pre_way].useful, tc_pre_correct) : 3'd1;
    tc_mode_we    = upd_valid && is_idirect_taken && (tc_pred_correct != tc_pre_correct);
    tc_mode_wdata = tc_pre_correct ? ((tc_mode_old < TC_MODE_MAX) ? tc_mode_old + 3'd1 : TC_MODE_MAX) :
                                     ((tc_mode_old > 3'd0) ? tc_mode_old - 3'd1 : 3'd0);
  end

endmodule

`default_nettype wire
