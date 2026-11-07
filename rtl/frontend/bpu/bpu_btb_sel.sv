// Ref: front-end/BPU/target_predictor/BTB_top.h  Btb::select (target of the first taken slot, compare stage)
`default_nettype none

// Target selection of one slot in the compare stage, on the registered S1 read data of its bank.
//   indirect jumps (idirect, icall): ITT hit (tag compare) else BTB hit else bank pc + 4;
//   conditional / call / jal / ret: BTB hit else bank pc + 4;  anything else: bank pc + 4.
// The fall-back is the BANK pc + 4, exactly like the C++ (the checker repairs such a prediction).
module bpu_btb_sel import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic [31:0]         bank_pc,
  input  logic [2:0]          br_type,
  input  btb_ent_t            btb_set [B_WAYS],
  input  logic                itt_valid,
  input  logic [T_TAG_W-1:0]  itt_entry_tag,
  input  logic [31:0]         itt_target,
  input  logic [T_TAG_W-1:0]  itt_tag,        // tag of the slot's TAGE table ITT_TBL
  output logic [31:0]         target
);

  logic [B_WAYS-1:0] hit_way;
  logic              btb_hit;
  logic [31:0]       btb_target;
  logic              itt_hit;

  // Ref: Btb::select
  always_comb begin
    for (int w = 0; w < B_WAYS; w++) hit_way[w] = btb_set[w].valid && (btb_set[w].tag == btb_tag_of(bank_pc));
    btb_hit    = |hit_way;
    btb_target = '0;
    for (int w = B_WAYS - 1; w >= 0; w--) if (hit_way[w]) btb_target = btb_set[w].bta;
    itt_hit = itt_valid && (itt_entry_tag == itt_tag);
    target  = bank_pc + 32'd4;
    if (br_type == BR_IDIRECT || br_type == BR_ICALL) begin
      if (itt_hit)      target = itt_target;
      else if (btb_hit) target = btb_target;
    end else if (br_type == BR_DIRECT || br_type == BR_CALL || br_type == BR_JAL || br_type == BR_RET) begin
      if (btb_hit) target = btb_target;
    end
  end

endmodule

`default_nettype wire
