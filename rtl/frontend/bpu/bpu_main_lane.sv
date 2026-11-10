// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::main_select (per slot part)
`default_nettype none

// Compare-stage result of one slot of the block in S2: branch type (type predictor tag compare), direction, target.
// The slot's bank data are chosen by the caller (slot i of a block that starts at bank b0 lives in bank b0 + i).
module bpu_main_lane import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic [31:BANK_W]    pc,           // slot pc without the byte / bank bits that are not needed
  input  logic                valid,           // pc < block end
  input  tp_entry_t           ty_way [TP_WAYS],
  input  logic                tg_pred,
  input  btb_ent_t            btb_set [B_WAYS],
  input  itt_ent_t [NITT-1:0] itt,
  input  logic [NITT-1:0][T_TAG_W-1:0] itt_tag,
  output logic [2:0]          ty,
  output logic                taken,
  output logic [31:0]         target
);

  logic [TP_WAYS-1:0] ty_hit;
  logic [TP_TAG_W-1:0] tag;
  logic [31:0]         bank_pc;

  // Ref: TypePred::select
  always_comb begin
    tag = pc[5 + TP_SET_W +: TP_TAG_W];
    for (int w = 0; w < TP_WAYS; w++) ty_hit[w] = ty_way[w].valid && (ty_way[w].tag == tag);
    ty = ty_hit[0] ? ty_way[0].br_type : ty_hit[1] ? ty_way[1].br_type : BR_NONCTL;
    // Ref: main_select: taken
    taken = valid && ty != BR_NONCTL &&
            (ty == BR_RET || ty == BR_CALL || ty == BR_ICALL || ty == BR_IDIRECT || ty == BR_JAL || tg_pred);
    bank_pc = {{BANK_W{1'b0}}, pc};
  end

  bpu_btb_sel u_sel (
    .bank_pc(bank_pc), .br_type(ty), .btb_set(btb_set), .itt(itt), .itt_tag(itt_tag), .target(target)
  );

endmodule

`default_nettype wire
