// Ref: front-end/BPU/BPU.h  class BPU_TOP  (comb/seq of bpu_comb_calc + bpu_seq_write)
`default_nettype none

// Branch prediction unit (default configuration: TAGE + BTB/TC + type predictor + RAS, no SC-L / loop / NLP).
// Port convention = spec/bpu.io (BPU_TOP::InputPayload / OutputPayload, dead fields removed, see docs/modules/bpu.md).
//   bpu_ctrl  : base pc / 8 lanes / pc register          bpu_type : branch type of every lane (8 banks x 512 x 2)
//   bpu_tage  : 8 banks of direction prediction          bpu_btb  : 8 banks of target prediction
//   bpu_pred  : first-taken-lane selection, next pc      bpu_hist : GHR/FH (Spec/Arch) + RAS
//   bpu_uq    : commit-update queue feeding TAGE/BTB the cycle after the commit
module bpu import bpu_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic [31:0]         refetch_address,
  input  logic                icache_read_ready,
  input  logic [NCOMMIT-1:0] upd_valid,
  input  logic [31:0]         base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0] actual_dir,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [31:0]         target     [NCOMMIT],
  input  logic [NCOMMIT-1:0] pred_dir,
  input  logic [NCOMMIT-1:0] alt_pred,
  input  logic [PCPN_W-1:0]   pcpn       [NCOMMIT],
  input  logic [T_TAG_W-1:0]  tags       [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs       [NCOMMIT][TN],
  output logic                icache_read_valid,
  output logic [31:0]         fetch_address,
  output logic                ptab_write_enable,
  output logic [31:0]         predict_next_fetch_address,
  output logic [NLANE-1:0] out_pred_dir,
  output logic [NLANE-1:0] out_alt_pred,
  output logic [PCPN_W-1:0]   out_pcpn     [NLANE],
  output logic [PCPN_W-1:0]   out_altpcpn  [NLANE],
  output logic [T_TAG_W-1:0]  out_tage_tags [NLANE][TN],
  output logic [T_IDX_W-1:0]  out_tage_idxs [NLANE][TN]
);

  // ---- fetch group ----
  logic [31:0]        boundary;
  logic [NLANE-1:0] lane_valid;
  logic [31:0]        lane_pc     [NLANE];
  logic [BANK_W-1:0]  bank_sel    [NLANE];
  logic               going_to_do_pred;
  logic [31:0]        next_pc;

  bpu_ctrl u_ctrl (
    .clk(clk), .rst_n(rst_n), .refetch(refetch), .refetch_address(refetch_address),
    .icache_read_ready(icache_read_ready), .next_pc(next_pc), .pred_base(fetch_address), .boundary(boundary),
    .lane_valid(lane_valid), .lane_pc(lane_pc), .going_to_do_pred(going_to_do_pred),
    .icache_read_valid(icache_read_valid), .ptab_write_enable(ptab_write_enable)
  );

  // ---- type predictor (prediction lanes + commit lanes) ----
  logic [NLANE-1:0] type_pred_valid;
  logic [2:0]         lane_type       [NLANE];

  always_comb begin
    for (int i = 0; i < NLANE; i++) begin
      bank_sel[i]        = lane_pc[i][BANK_W + 1:2];
      type_pred_valid[i] = going_to_do_pred && lane_valid[i];
    end
  end

  bpu_type u_type (
    .clk(clk), .rst_n(rst_n), .pred_valid(type_pred_valid), .pred_pc(lane_pc), .upd_valid(upd_valid),
    .upd_pc(base_pc), .upd_br_type(br_type), .pred_type(lane_type)
  );

  // ---- per-bank lookup requests: lane i uses the bank of its pc, the 8 lanes cover the 8 banks once ----
  logic [NBANK-1:0] bank_req;
  logic [BPC_W-1:0]   bank_pc       [NBANK];
  logic [2:0]         bank_type     [NBANK];

  for (genvar b = 0; b < NBANK; b++) begin : g_req
    logic [NLANE-1:0] hit_lane;                 // lane that maps to bank b (at most one)
    logic [BPC_W-1:0] lane_bank_pc [NLANE];
    logic [2:0]       lane_type_of [NLANE];
    always_comb begin
      for (int i = 0; i < NLANE; i++) begin
        hit_lane[i]      = type_pred_valid[i] && (bank_sel[i] == BANK_W'(b));
        lane_bank_pc[i]  = lane_pc[i][31:BANK_W];
        lane_type_of[i]  = lane_type[i];
      end
    end
    assign bank_req[b] = |hit_lane;
    ttg_onehot_mux #(.N(NLANE), .W(BPC_W)) u_pc (.sel(hit_lane), .data(lane_bank_pc), .out(bank_pc[b]));
    ttg_onehot_mux #(.N(NLANE), .W(3)) u_type (.sel(hit_lane), .data(lane_type_of), .out(bank_type[b]));
  end

  // ---- update queue ----
  logic [NBANK-1:0] q_valid;
  logic [BPC_W-1:0]   q_pc      [NBANK];
  logic [31:0]        q_target  [NBANK];
  logic [2:0]         q_br_type [NBANK];
  logic [NBANK-1:0] q_dir;
  logic [NBANK-1:0] tage_en;
  logic [NBANK-1:0] q_pred_dir;
  logic [NBANK-1:0] q_alt_pred;
  logic [PCPN_W-1:0]  q_pcpn    [NBANK];
  logic [T_TAG_W-1:0] q_tags    [NBANK][TN];
  logic [T_IDX_W-1:0] q_idxs    [NBANK][TN];

  bpu_uq u_uq (
    .clk(clk), .rst_n(rst_n), .upd_valid(upd_valid), .base_pc(base_pc), .actual_dir(actual_dir), .br_type(br_type),
    .target(target), .pred_dir(pred_dir), .alt_pred(alt_pred), .pcpn(pcpn), .tags(tags), .idxs(idxs),
    .q_valid(q_valid), .q_pc(q_pc), .q_target(q_target), .q_br_type(q_br_type), .q_dir(q_dir), .tage_en(tage_en),
    .q_pred_dir(q_pred_dir), .q_alt_pred(q_alt_pred), .q_pcpn(q_pcpn), .q_tags(q_tags), .q_idxs(q_idxs)
  );

  // ---- history / RAS ----
  logic [NLANE-1:0] lane_taken;
  logic [FH_W-1:0]    fh         [FH_K][TN];
  logic               ras_has;
  logic [31:0]        ras_top;

  bpu_hist u_hist (
    .clk(clk), .rst_n(rst_n), .refetch(refetch), .pred_en(going_to_do_pred), .lane_valid(lane_valid),
    .lane_pc(lane_pc), .lane_type(lane_type), .lane_taken(lane_taken), .upd_valid(upd_valid), .upd_pc(base_pc),
    .actual_dir(actual_dir), .br_type(br_type), .pred_dir(pred_dir), .fh(fh), .ras_has(ras_has), .ras_top(ras_top)
  );

  // ---- TAGE and BTB banks ----
  logic [T_BASE_W-1:0] tage_pred_pc_idx [NBANK];
  logic [T_BASE_W-1:0] tage_upd_pc_idx  [NBANK];
  logic [NBANK-1:0] tage_pred_out;
  logic [NBANK-1:0] tage_alt_out;
  logic [PCPN_W-1:0]   tage_pcpn_out    [NBANK];
  logic [PCPN_W-1:0]   tage_altpcpn_out [NBANK];
  logic [T_TAG_W-1:0]  tage_tag_out     [NBANK][TN];
  logic [T_IDX_W-1:0]  tage_idx_out     [NBANK][TN];
  logic [31:0]         btb_target       [NBANK];

  always_comb begin
    for (int b = 0; b < NBANK; b++) begin
      tage_pred_pc_idx[b] = bank_pc[b][T_BASE_W + 1:2];     // (bank pc >> 2) & 1023
      tage_upd_pc_idx[b]  = q_pc[b][T_BASE_W + 1:2];
    end
  end

  bpu_tage u_tage (
    .clk(clk), .rst_n(rst_n), .fh(fh), .pred_req(bank_req), .pred_pc_idx(tage_pred_pc_idx), .update_en(tage_en),
    .upd_pc_idx(tage_upd_pc_idx), .real_dir(q_dir), .pred_in(q_pred_dir), .alt_pred_in(q_alt_pred),
    .pcpn_in(q_pcpn), .tag_in(q_tags), .idx_in(q_idxs), .pred_out(tage_pred_out), .alt_pred_out(tage_alt_out),
    .pcpn_out(tage_pcpn_out), .altpcpn_out(tage_altpcpn_out), .tag_out(tage_tag_out), .idx_out(tage_idx_out)
  );

  bpu_btb u_btb (
    .clk(clk), .rst_n(rst_n), .pred_req(bank_req), .pred_pc(bank_pc), .pred_type_in(bank_type),
    .upd_valid(q_valid), .upd_pc(q_pc), .upd_actual_addr(q_target), .upd_br_type_in(q_br_type),
    .upd_actual_dir(q_dir), .pred_target(btb_target)
  );

  // ---- combine ----
  bpu_pred u_pred (
    .going_to_do_pred(going_to_do_pred), .lane_valid(lane_valid), .bank_sel(bank_sel), .boundary(boundary),
    .lane_type(lane_type), .tage_pred(tage_pred_out), .tage_alt(tage_alt_out), .tage_pcpn(tage_pcpn_out),
    .tage_altpcpn(tage_altpcpn_out), .tage_tags(tage_tag_out), .tage_idxs(tage_idx_out), .btb_target(btb_target),
    .ras_has(ras_has), .ras_top(ras_top), .lane_taken(lane_taken), .out_alt_pred(out_alt_pred),
    .out_pcpn(out_pcpn), .out_altpcpn(out_altpcpn), .out_tags(out_tage_tags), .out_idxs(out_tage_idxs),
    .next_pc(next_pc)
  );

  assign predict_next_fetch_address = next_pc;
  assign out_pred_dir               = lane_taken;

endmodule

`default_nettype wire
