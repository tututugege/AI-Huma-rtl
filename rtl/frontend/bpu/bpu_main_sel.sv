// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::main_select
`default_nettype none

// Compare / select stage of the main predictor for the block in S2: every slot's type, direction and target, the first
// taken slot, and what the block pushes into the history / RAS.  Pure function of the registered S1 read data.
//   Per-slot results are made in bank order of the arrays and picked by slot (slot i -> bank base_bank + i).
module bpu_main_sel import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic [31:0]         base,
  input  logic                ck_ras_nonempty,
  input  logic [31:0]         ck_ras_top,
  input  tp_entry_t           ty_way   [NBANK][TP_WAYS],
  input  logic [NBANK-1:0]    tg_pred,
  input  logic [NBANK-1:0]    tg_alt,
  input  logic [PCPN_W-1:0]   tg_pcpn    [NBANK],
  input  logic [PCPN_W-1:0]   tg_altpcpn [NBANK],
  input  tg_ix_t              ix       [NBANK],
  input  btb_ent_t            btb_set  [NBANK][B_WAYS],
  input  itt_ent_t            itt      [NBANK],
  output pred_t               pred,
  output logic [NLANE-1:0]    lane_dir,
  output logic [NLANE-1:0]    lane_alt,
  output logic [PCPN_W-1:0]   lane_pcpn    [NLANE],
  output logic [PCPN_W-1:0]   lane_altpcpn [NLANE],
  output logic [T_TAG_W-1:0]  lane_tag     [NLANE][TN],
  output logic [T_IDX_W-1:0]  lane_idx     [NLANE][TN]
);

  logic [31:0]        bnd;
  logic [31:0]        lane_pc     [NLANE];
  logic [NLANE-1:0]   lane_valid;
  logic [BANK_W-1:0]  lane_bank   [NLANE];
  logic [2:0]         lane_ty     [NLANE];
  logic [NLANE-1:0]   lane_taken;
  logic [31:0]        lane_target [NLANE];
  logic [NLANE-1:0]   first_taken;
  logic               any_taken;
  logic [31:0]        first_pc;
  logic [31:0]        first_target;
  logic [2:0]         first_ty;
  logic [2:0]         first_slot;

  always_comb begin
    bnd = block_bnd(base);
    for (int i = 0; i < NLANE; i++) begin
      lane_pc[i]    = base + 32'(4 * i);
      lane_valid[i] = lane_pc[i] < bnd;
      lane_bank[i]  = base[BANK_W + 1:2] + BANK_W'(i);
    end
  end

  for (genvar i = 0; i < NLANE; i++) begin : g_lane
    bpu_main_lane u_lane (
      .pc(lane_pc[i][31:BANK_W]), .valid(lane_valid[i]), .ty_way(ty_way[lane_bank[i]]),
      .tg_pred(tg_pred[lane_bank[i]]),
      .btb_set(btb_set[lane_bank[i]]), .itt_valid(itt[lane_bank[i]].valid),
      .itt_entry_tag(itt[lane_bank[i]].tag), .itt_target(itt[lane_bank[i]].target),
      .itt_tag(ix[lane_bank[i]].tag[ITT_TBL]),
      .ty(lane_ty[i]), .taken(lane_taken[i]), .target(lane_target[i])
    );
    // slot metadata of the prediction (zero for slots beyond the block end)
    assign lane_dir[i]    = lane_taken[i];
    assign lane_alt[i]    = lane_valid[i] && tg_alt[lane_bank[i]];
    assign lane_pcpn[i]   = lane_valid[i] ? tg_pcpn[lane_bank[i]] : '0;
    assign lane_altpcpn[i] = lane_valid[i] ? tg_altpcpn[lane_bank[i]] : '0;
    for (genvar k = 0; k < TN; k++) begin : g_tn
      assign lane_tag[i][k] = lane_valid[i] ? ix[lane_bank[i]].tag[k] : '0;
      assign lane_idx[i][k] = lane_valid[i] ? ix[lane_bank[i]].idx[k] : '0;
    end
  end

  ttg_first_set #(.N(NLANE)) u_first (.req(lane_taken), .onehot(first_taken), .any(any_taken));
  ttg_onehot_mux #(.N(NLANE), .W(32)) u_pc (.sel(first_taken), .data(lane_pc), .out(first_pc));
  ttg_onehot_mux #(.N(NLANE), .W(32)) u_tgt (.sel(first_taken), .data(lane_target), .out(first_target));
  ttg_onehot_mux #(.N(NLANE), .W(3)) u_ty (.sel(first_taken), .data(lane_ty), .out(first_ty));

  // Ref: main_select: first taken slot -> next pc (RET with a non-empty RAS: top of the block's checkpoint),
  // history bits and RAS operation
  always_comb begin
    first_slot = '0;
    for (int i = 0; i < NLANE; i++) if (first_taken[i]) first_slot = 3'(i);
    pred       = '0;
    pred.taken = any_taken;
    pred.next  = bnd;
    if (any_taken) begin
      pred.slot  = first_slot;
      pred.ty    = first_ty;
      pred.next  = (first_ty == BR_RET && ck_ras_nonempty) ? ck_ras_top : first_target;
      pred.hbits = hsym_of(first_pc, pred.next);
      if (first_ty == BR_CALL || first_ty == BR_ICALL) begin
        pred.ras_op  = 2'd1;
        pred.ras_val = first_pc + 32'd4;
      end else if (first_ty == BR_RET) begin
        pred.ras_op = 2'd2;
      end
    end
  end

endmodule

`default_nettype wire
