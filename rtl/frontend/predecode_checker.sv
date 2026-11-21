// Ref: front-end/predecode_checker.cpp  predecode_check (single-block & 2-taken dual-segment check)
`default_nettype none

module predecode_checker import ttg_cfg_pkg::*; import front_pkg::*; (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic                   clk,
  input  logic                   rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
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

  logic [FETCH_WIDTH-1:0] taken;
  logic [FETCH_WIDTH-1:0] first_taken_onehot;
  logic                   any_taken;
  logic [FETCH_WIDTH-1:0] lane_uses_target;
  logic [XLEN_BITS-1:0]   first_taken_target;
  logic                   first_taken_uses_target;

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

  // Dual-segment check for 2-taken paired groups (multi == 1: segment 0 = [0..s1-1], segment 1 = [s1..e1])
  logic [3:0]           s1_idx, e1_idx;
  logic                 any_ft0, any_lv0, any_ft1, bad0;
  logic [3:0]           ft0, lv0, ft1;
  logic [XLEN_BITS-1:0] claimed0, corr0, corr1;
  logic [4:0]           keep0, keep1;

  always_comb begin
    s1_idx  = 4'd0;
    e1_idx  = 4'd0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if (seg_first[i] && (s1_idx == 4'd0)) s1_idx = 4'(i);
      if (in_range[i])                      e1_idx = 4'(i);
    end
    any_ft0 = 1'b0; ft0 = 4'd0;
    any_lv0 = 1'b0; lv0 = 4'd0;
    any_ft1 = 1'b0; ft1 = 4'd0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if (4'(i) < s1_idx) begin
        if (inst_valid[i])          begin any_lv0 = 1'b1; lv0 = 4'(i); end
        if (!any_ft0 && taken[i])   begin any_ft0 = 1'b1; ft0 = 4'(i); end
      end else if (4'(i) <= e1_idx) begin
        if (!any_ft1 && taken[i])   begin any_ft1 = 1'b1; ft1 = 4'(i); end
      end
    end
    claimed0 = slot_pc[s1_idx];
    if (any_ft0) begin
      corr0 = lane_uses_target[ft0] ? predecode_target_address[ft0] : claimed0;
      keep0 = {1'b0, ft0} + 5'd1;
    end else begin
      corr0 = any_lv0 ? (slot_pc[lv0] + (is_rvc[lv0] ? XLEN_BITS'(2) : XLEN_BITS'(4)))
                      : (slot_pc[s1_idx - 4'd1] + XLEN_BITS'(SLOT_BYTES));
      keep0 = {1'b0, s1_idx};
    end
    bad0 = (corr0 != claimed0) || !any_ft0 || (ft0 != (s1_idx - 4'd1)) || !inst_valid[s1_idx];

    if (any_ft1) begin
      corr1 = lane_uses_target[ft1] ? predecode_target_address[ft1] : predict_next_fetch_address;
      keep1 = {1'b0, ft1} + 5'd1;
    end else begin
      corr1 = seq_next_pc;
      keep1 = {1'b0, e1_idx} + 5'd1;
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

endmodule

`default_nettype wire
