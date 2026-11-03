// Ref: front-end/BPU/BPU.h  BPU_TOP::bpu_predict_main_comb
`default_nettype none

// Combine type prediction, TAGE direction and BTB / RAS target of the 8 lanes of a fetch group.
//   pred_taken: NONCTL -> 0; RET/CALL/IDIRECT/JAL -> 1; otherwise (conditional branch) the TAGE direction
//   per-lane metadata: alt_pred / pcpn / altpcpn / tags / idxs of the TAGE bank of that lane (0 for inactive lanes)
//   next pc: boundary, or for the FIRST taken lane its BTB target (RET with a non-empty RAS: the RAS top)
module bpu_pred import bpu_pkg::*; (
  input  logic                going_to_do_pred,
  input  logic                lane_valid   [NLANE],
  input  logic [BANK_W-1:0]   bank_sel     [NLANE],
  input  logic [31:0]         boundary,
  input  logic [2:0]          lane_type    [NLANE],
  // per-bank results of this cycle's lookups
  input  logic                tage_pred    [NBANK],
  input  logic                tage_alt     [NBANK],
  input  logic [PCPN_W-1:0]   tage_pcpn    [NBANK],
  input  logic [PCPN_W-1:0]   tage_altpcpn [NBANK],
  input  logic [T_TAG_W-1:0]  tage_tags    [NBANK][TN],
  input  logic [T_IDX_W-1:0]  tage_idxs    [NBANK][TN],
  input  logic [31:0]         btb_target   [NBANK],
  input  logic                ras_has,
  input  logic [31:0]         ras_top,
  // outputs
  output logic                lane_taken   [NLANE],        // final_pred_dir
  output logic                out_alt_pred [NLANE],
  output logic [PCPN_W-1:0]   out_pcpn     [NLANE],
  output logic [PCPN_W-1:0]   out_altpcpn  [NLANE],
  output logic [T_TAG_W-1:0]  out_tags     [NLANE][TN],
  output logic [T_IDX_W-1:0]  out_idxs     [NLANE][TN],
  output logic [31:0]         next_pc
);

  logic [NLANE-1:0] act;
  logic [NLANE-1:0] taken_vec;
  logic [NLANE-1:0] first_taken;
  logic             any_taken;
  logic [31:0]      lane_target [NLANE];

  always_comb begin
    for (int i = 0; i < NLANE; i++) begin
      act[i] = going_to_do_pred && lane_valid[i];
      case (lane_type[i])
        BR_NONCTL: lane_taken[i] = 1'b0;
        BR_RET, BR_CALL, BR_IDIRECT, BR_JAL: lane_taken[i] = act[i];
        default: lane_taken[i] = act[i] && tage_pred[bank_sel[i]];
      endcase
      taken_vec[i]    = lane_taken[i];
      out_alt_pred[i] = act[i] && tage_alt[bank_sel[i]];
      out_pcpn[i]     = act[i] ? tage_pcpn[bank_sel[i]] : '0;
      out_altpcpn[i]  = act[i] ? tage_altpcpn[bank_sel[i]] : '0;
      for (int t = 0; t < TN; t++) begin
        out_tags[i][t] = act[i] ? tage_tags[bank_sel[i]][t] : '0;
        out_idxs[i][t] = act[i] ? tage_idxs[bank_sel[i]][t] : '0;
      end
      lane_target[i] = (lane_type[i] == BR_RET && ras_has) ? ras_top : btb_target[bank_sel[i]];
    end
  end

  ttg_first_set #(.N(NLANE)) u_first (.req(taken_vec), .onehot(first_taken), .any(any_taken));

  logic [31:0] first_target;
  ttg_onehot_mux #(.N(NLANE), .W(32)) u_target (.sel(first_taken), .data(lane_target), .out(first_target));

  assign next_pc = any_taken ? first_target : boundary;

endmodule

`default_nettype wire
