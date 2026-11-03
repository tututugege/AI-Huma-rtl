// Ref: front-end/BPU/target_predictor/BTB_top.h  BTB_TOP::btb_pred_output_comb
`default_nettype none

// Predicted target of one BTB bank for one lookup.  `pc` is the BANK pc (pc>>3), exactly as the C++ passes it: the
// "not found" fallback is therefore bank_pc + 4 (a model quirk, kept because it changes the fetch address).
module bpu_btb_pred import bpu_pkg::*; import bpu_btb_pkg::*; (
  input  logic [31:0]  pc,
  input  logic [2:0]   br_type,
  input  btb_ent_t     btb_set    [B_WAYS],
  input  tc_ent_t      tc_set     [TC_WAYS],
  input  tc_ent_t      tc_pre_set [TC_WAYS],
  input  logic [2:0]   tc_mode,
  output logic [31:0]  pred_target
);

  logic [B_WAYS-1:0]  btb_hit_way;
  logic [TC_WAYS-1:0] tc_hit_way;
  logic [TC_WAYS-1:0] tc_pre_hit_way;
  logic [TC_TAG_W-1:0] tc_tag;
  logic [31:0]        btb_target;
  logic [31:0]        tc_target;
  logic [31:0]        tc_pre_target;
  logic               btb_hit;
  logic               tc_hit;
  logic               tc_pre_hit;
  logic [31:0]        pc_plus4;

  always_comb begin
    tc_tag   = tc_tag_of(pc);
    pc_plus4 = pc + 32'd4;
    for (int w = 0; w < B_WAYS; w++) btb_hit_way[w] = btb_set[w].valid && (btb_set[w].tag == btb_tag_of(pc));
    for (int w = 0; w < TC_WAYS; w++) begin
      tc_hit_way[w]     = tc_set[w].valid && (tc_set[w].tag == tc_tag);
      tc_pre_hit_way[w] = tc_pre_set[w].valid && (tc_pre_set[w].tag == tc_tag);
    end
    btb_hit    = |btb_hit_way;
    tc_hit     = |tc_hit_way;
    tc_pre_hit = |tc_pre_hit_way;
    // first matching way (lowest index) supplies the target
    btb_target = '0;
    for (int w = B_WAYS - 1; w >= 0; w--) if (btb_hit_way[w]) btb_target = btb_set[w].bta;
    tc_target = pc_plus4;
    for (int w = TC_WAYS - 1; w >= 0; w--) if (tc_hit_way[w]) tc_target = tc_set[w].target;
    tc_pre_target = pc_plus4;
    for (int w = TC_WAYS - 1; w >= 0; w--) if (tc_pre_hit_way[w]) tc_pre_target = tc_pre_set[w].target;
  end

  // Ref: btb_pred_output_comb
  always_comb begin
    pred_target = pc_plus4;
    if (br_type == BR_IDIRECT) begin
      if (tc_pre_hit && (!tc_hit || tc_mode >= TC_MODE_BIAS)) pred_target = tc_pre_target;
      else if (tc_hit)                                        pred_target = tc_target;
      else if (btb_hit)                                       pred_target = btb_target;   // INDIRECT_BTB_FALLBACK
    end else if (br_type == BR_DIRECT || br_type == BR_CALL || br_type == BR_JAL || br_type == BR_RET) begin
      if (btb_hit) pred_target = btb_target;
    end
  end

endmodule

`default_nettype wire
