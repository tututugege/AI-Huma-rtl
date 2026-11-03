// Ref: front-end/BPU/BPU.h  BPU_TOP::bpu_hist_comb  (Spec/Arch GHR + folded histories + RAS)
`default_nettype none

// Branch history (speculative and architectural copies) and the return address stack.
//  Spec update (pred_en && !refetch): fetch-group lanes in order; a DIRECT lane shifts its predicted direction in; the
//   first TAKEN lane (any type) ends the update (and is the RAS op: CALL pushes pc+4, RET pops).
//  Arch update: commit lanes in order; a committed DIRECT branch shifts its real direction into the Arch history; if it
//   was mispredicted the Spec history is replaced by the Arch value after that branch (a later such lane wins).
//  refetch: Spec := Arch (after this cycle's commits) and has priority over everything.
// `fh` (output) is the speculative folded history at the start of the cycle: the TAGE index/tag input.
module bpu_hist import bpu_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic                pred_en,                 // going_to_do_pred
  input  logic                lane_valid  [NLANE],     // do_pred_on_this_pc
  input  logic [31:0]         lane_pc     [NLANE],
  input  logic [2:0]          lane_type   [NLANE],
  input  logic                lane_taken  [NLANE],     // final_pred_dir
  input  logic                upd_valid   [NCOMMIT],
  input  logic [31:0]         upd_pc      [NCOMMIT],
  input  logic                actual_dir  [NCOMMIT],
  input  logic [2:0]          br_type     [NCOMMIT],
  input  logic                pred_dir    [NCOMMIT],
  output logic [FH_W-1:0]     fh          [FH_K][TN],
  output logic                ras_has,
  output logic [31:0]         ras_top
);

  // ---- state ----
  logic [GHR_W-1:0] spec_ghr_q, spec_ghr_d, arch_ghr_q, arch_ghr_d;
  logic [FH_FLAT-1:0] spec_fh_q, spec_fh_d, arch_fh_q, arch_fh_d;

  // ---- speculative chain over the fetch-group lanes ----
  logic                  pred_gate;
  logic [NLANE-1:0]      taken_lane;        // lane valid and predicted taken
  logic [NLANE-1:0]      first_taken;
  logic                  any_taken;
  logic [NLANE-1:0]      before_taken;      // a taken lane exists below
  logic [NLANE-1:0]      spec_apply;
  logic [GHR_W-1:0]      sp_ghr [NLANE + 1];
  logic [FH_FLAT-1:0]    sp_fh  [NLANE + 1];

  always_comb begin
    pred_gate = pred_en && !refetch;
    for (int l = 0; l < NLANE; l++) taken_lane[l] = lane_valid[l] && lane_taken[l];
    for (int l = 0; l < NLANE; l++)
      before_taken[l] = (l == 0) ? 1'b0 : |(taken_lane & ((NLANE'(1) << l) - NLANE'(1)));
    for (int l = 0; l < NLANE; l++)
      spec_apply[l] = pred_gate && lane_valid[l] && !before_taken[l] && (lane_type[l] == BR_DIRECT);
  end

  ttg_first_set #(.N(NLANE)) u_first_taken (.req(taken_lane), .onehot(first_taken), .any(any_taken));

  assign sp_ghr[0] = spec_ghr_q;
  assign sp_fh[0]  = spec_fh_q;
  for (genvar l = 0; l < NLANE; l++) begin : g_spec
    bpu_hist_stage u_stage (
      .en(spec_apply[l]), .new_hist(lane_taken[l]), .ghr_in(sp_ghr[l]), .fh_in(sp_fh[l]),
      .ghr_out(sp_ghr[l + 1]), .fh_out(sp_fh[l + 1])
    );
  end

  // ---- architectural chain over the commit lanes ----
  logic [NCOMMIT-1:0] arch_apply;
  logic [NCOMMIT-1:0] arch_mispred;
  logic [GHR_W-1:0]   ar_ghr [NCOMMIT + 1];
  logic [FH_FLAT-1:0] ar_fh  [NCOMMIT + 1];

  always_comb begin
    for (int l = 0; l < NCOMMIT; l++) begin
      arch_apply[l]   = upd_valid[l] && (br_type[l] == BR_DIRECT);
      arch_mispred[l] = arch_apply[l] && (pred_dir[l] != actual_dir[l]);
    end
  end

  assign ar_ghr[0] = arch_ghr_q;
  assign ar_fh[0]  = arch_fh_q;
  for (genvar l = 0; l < NCOMMIT; l++) begin : g_arch
    bpu_hist_stage u_stage (
      .en(arch_apply[l]), .new_hist(actual_dir[l]), .ghr_in(ar_ghr[l]), .fh_in(ar_fh[l]),
      .ghr_out(ar_ghr[l + 1]), .fh_out(ar_fh[l + 1])
    );
  end

  // ---- next state ----
  // Spec := (last mispredicted commit lane's Arch value) else (prediction chain); refetch overrides with the new Arch
  logic [GHR_W-1:0] ovr_ghr;
  logic [FH_FLAT-1:0] ovr_fh;

  always_comb begin
    ovr_ghr     = sp_ghr[NLANE];
    for (int l = 0; l < NCOMMIT; l++) if (arch_mispred[l]) ovr_ghr = ar_ghr[l + 1];
    arch_ghr_d  = ar_ghr[NCOMMIT];
    spec_ghr_d  = refetch ? arch_ghr_d : ovr_ghr;
  end

  always_comb begin
    ovr_fh = sp_fh[NLANE];
    for (int l = 0; l < NCOMMIT; l++) if (arch_mispred[l]) ovr_fh = ar_fh[l + 1];
    arch_fh_d = ar_fh[NCOMMIT];
    spec_fh_d = refetch ? arch_fh_d : ovr_fh;
  end

  for (genvar k = 0; k < FH_K; k++) begin : g_out_k
    for (genvar i = 0; i < TN; i++) begin : g_out_i
      assign fh[k][i] = spec_fh_q[(k * TN + i) * FH_W +: FH_W];
    end
  end

  // ---- RAS ----
  logic                spec_push;
  logic                spec_pop;
  logic [31:0]         spec_push_val;
  logic                arch_push     [NCOMMIT];
  logic                arch_pop      [NCOMMIT];
  logic [31:0]         arch_push_val [NCOMMIT];
  logic [31:0]         first_taken_pc;
  logic [2:0]          spec_taken_type;

  ttg_onehot_mux #(.N(NLANE), .W(32)) u_taken_pc (.sel(first_taken), .data(lane_pc), .out(first_taken_pc));
  ttg_onehot_mux #(.N(NLANE), .W(3)) u_taken_type (.sel(first_taken), .data(lane_type), .out(spec_taken_type));

  always_comb begin
    spec_push     = pred_gate && any_taken && (spec_taken_type == BR_CALL);
    spec_pop      = pred_gate && any_taken && (spec_taken_type == BR_RET);
    spec_push_val = first_taken_pc + 32'd4;
    for (int l = 0; l < NCOMMIT; l++) begin
      arch_push[l]     = upd_valid[l] && (br_type[l] == BR_CALL);
      arch_pop[l]      = upd_valid[l] && (br_type[l] == BR_RET);
      arch_push_val[l] = upd_pc[l] + 32'd4;
    end
  end

  bpu_ras u_ras (
    .clk(clk), .rst_n(rst_n), .refetch(refetch), .spec_push(spec_push), .spec_pop(spec_pop),
    .spec_push_val(spec_push_val), .arch_push(arch_push), .arch_pop(arch_pop), .arch_push_val(arch_push_val),
    .top_has(ras_has), .top_val(ras_top)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_ghr_q <= '0;
      arch_ghr_q <= '0;
      spec_fh_q  <= '0;
      arch_fh_q  <= '0;
    end else begin
      spec_ghr_q <= spec_ghr_d;
      arch_ghr_q <= arch_ghr_d;
      spec_fh_q  <= spec_fh_d;
      arch_fh_q  <= arch_fh_d;
    end
  end

endmodule

`default_nettype wire
