// Ref: front-end/predecode_checker.cpp  predecode_check (log-depth parallel single-block & 2-taken dual-segment check)
`default_nettype none

module predecode_checker import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                   multi,
  input  logic [FETCH_WIDTH-1:0] in_range,
  input  logic [FETCH_WIDTH-1:0] seg_first,
  input  logic [XLEN_BITS-1:0]   slot_pc                  [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] inst_valid,
  input  logic [FETCH_WIDTH-1:0] is_rvc,
  input  logic [FETCH_WIDTH-1:0] predict_dir,
  input  logic [XLEN_BITS-1:0]   predict_next_fetch_address,
  input  logic [1:0]             predecode_type           [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]   predecode_target_address [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]   seq_next_pc,
  output logic [FETCH_WIDTH-1:0] predict_dir_corrected,
  output logic [XLEN_BITS-1:0]   predict_next_fetch_address_corrected,
  output logic                   predecode_flush_enable,
  output logic [4:0]             keep_n
);

  logic [FETCH_WIDTH-1:0] taken, lane_uses_target;
  logic [FETCH_WIDTH-1:0] first_taken_onehot;
  logic                   any_taken, first_taken_uses_target;
  logic [XLEN_BITS-1:0]   first_taken_target;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      case (predecode_type[i])
        PREDECODE_DIRECT_JUMP_NO_JAL: taken[i] = predict_dir[i];
        PREDECODE_JALR:               taken[i] = 1'b1;
        PREDECODE_JAL:                taken[i] = 1'b1;
        default:                      taken[i] = 1'b0;
      endcase
      predict_dir_corrected[i] = taken[i];
      lane_uses_target[i]      = (predecode_type[i] == PREDECODE_DIRECT_JUMP_NO_JAL) ||
                                 (predecode_type[i] == PREDECODE_JAL);
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_first_taken (.req(taken), .onehot(first_taken_onehot), .any(any_taken));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_first_taken_target (
    .sel(first_taken_onehot), .data(predecode_target_address), .out(first_taken_target)
  );
  assign first_taken_uses_target = |(first_taken_onehot & lane_uses_target);

  // ---- Log-depth parallel dual-segment check (multi == 1: seg0 = [0..s1-1], seg1 = [s1..e1]) ----
  logic [FETCH_WIDTH-1:0] s1_oh, s1_prev_oh, seg1_ge, m0, m1;
  logic [FETCH_WIDTH-1:0] ir_rev, e1_rev_oh, e1_oh;
  logic [FETCH_WIDTH-1:0] ft0_oh, ft1_oh, lv0_rev_req, lv0_rev_oh, lv0_oh;
  logic                   any_s1, any_e1, any_ft0, any_ft1, any_lv0;
  logic [3:0]             s1_idx, e1_idx, ft0, ft1;

  ttg_first_set #(.N(FETCH_WIDTH)) u_s1 (.req(seg_first), .onehot(s1_oh), .any(any_s1));
  ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_s1_i (.onehot(s1_oh), .idx(s1_idx));
  assign s1_prev_oh = {1'b0, s1_oh[FETCH_WIDTH-1:1]};

  always_comb begin
    seg1_ge = s1_oh;
    seg1_ge = seg1_ge | (seg1_ge << 1);
    seg1_ge = seg1_ge | (seg1_ge << 2);
    seg1_ge = seg1_ge | (seg1_ge << 4);
    seg1_ge = seg1_ge | (seg1_ge << 8);
    m0 = ~seg1_ge;
    m1 = seg1_ge & in_range;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      ir_rev[i]      = in_range[FETCH_WIDTH - 1 - i];
      lv0_rev_req[i] = inst_valid[FETCH_WIDTH - 1 - i] & m0[FETCH_WIDTH - 1 - i];
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_e1_r (.req(ir_rev), .onehot(e1_rev_oh), .any(any_e1));
  ttg_first_set #(.N(FETCH_WIDTH)) u_lv0_r (.req(lv0_rev_req), .onehot(lv0_rev_oh), .any(any_lv0));
  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      e1_oh[i]  = e1_rev_oh[FETCH_WIDTH - 1 - i];
      lv0_oh[i] = lv0_rev_oh[FETCH_WIDTH - 1 - i];
    end
  end
  ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_e1_i (.onehot(e1_oh), .idx(e1_idx));

  ttg_first_set #(.N(FETCH_WIDTH)) u_ft0 (.req(taken & m0), .onehot(ft0_oh), .any(any_ft0));
  ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_ft0_i (.onehot(ft0_oh), .idx(ft0));

  ttg_first_set #(.N(FETCH_WIDTH)) u_ft1 (.req(taken & m1), .onehot(ft1_oh), .any(any_ft1));
  ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_ft1_i (.onehot(ft1_oh), .idx(ft1));

  logic [XLEN_BITS-1:0] claimed0, ft0_tgt, ft1_tgt, lv0_pc, s1_prev_pc, corr0, corr1;
  logic                 ft0_uses_tgt, ft1_uses_tgt, lv0_is_rvc, s1_inst_v, bad0;
  logic [4:0]           keep0, keep1;

  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_cl0    (.sel(s1_oh),      .data(slot_pc),                  .out(claimed0));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_ft0_t  (.sel(ft0_oh),     .data(predecode_target_address), .out(ft0_tgt));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_ft1_t  (.sel(ft1_oh),     .data(predecode_target_address), .out(ft1_tgt));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_lv0_p  (.sel(lv0_oh),     .data(slot_pc),                  .out(lv0_pc));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_s1p_p  (.sel(s1_prev_oh), .data(slot_pc),                  .out(s1_prev_pc));

  assign ft0_uses_tgt = |(ft0_oh & lane_uses_target);
  assign ft1_uses_tgt = |(ft1_oh & lane_uses_target);
  assign lv0_is_rvc   = |(lv0_oh & is_rvc);
  assign s1_inst_v    = |(s1_oh  & inst_valid);

  always_comb begin
    if (any_ft0) begin
      corr0 = ft0_uses_tgt ? ft0_tgt : claimed0;
      keep0 = {1'b0, ft0} + 5'd1;
    end else begin
      corr0 = any_lv0 ? (lv0_pc + (lv0_is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4)))
                      : (s1_prev_pc + XLEN_BITS'(SLOT_BYTES));
      keep0 = {1'b0, s1_idx};
    end
    bad0 = (corr0 != claimed0) || !any_ft0 || (ft0_oh != s1_prev_oh) || !s1_inst_v;

    if (any_ft1) begin
      corr1 = ft1_uses_tgt ? ft1_tgt : predict_next_fetch_address;
      keep1 = {1'b0, ft1} + 5'd1;
    end else begin
      corr1 = seq_next_pc;
      keep1 = any_e1 ? ({1'b0, e1_idx} + 5'd1) : 5'd1;
    end
  end

  always_comb begin
    if (multi) begin
      if (bad0) begin
        predict_next_fetch_address_corrected = corr0;
        predecode_flush_enable               = 1'b1;
        keep_n                               = keep0;
      end else begin
        predict_next_fetch_address_corrected = corr1;
        predecode_flush_enable               = (corr1 != predict_next_fetch_address);
        keep_n                               = keep1;
      end
    end else begin
      if (!any_taken)                   predict_next_fetch_address_corrected = seq_next_pc;
      else if (first_taken_uses_target) predict_next_fetch_address_corrected = first_taken_target;
      else                              predict_next_fetch_address_corrected = predict_next_fetch_address;
      predecode_flush_enable = (predict_next_fetch_address != predict_next_fetch_address_corrected);
      keep_n                 = 5'(FETCH_WIDTH);
    end
  end

  logic unused_chk;
  assign unused_chk = any_s1;

endmodule

`default_nettype wire
