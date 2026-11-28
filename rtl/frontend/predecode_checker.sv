// Ref: front-end/predecode_checker.cpp  predecode_check (log-depth parallel single-block check)
`default_nettype none

module predecode_checker import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic [FETCH_WIDTH-1:0] predict_dir,
  input  logic [XLEN_BITS-1:0]   predict_next_fetch_address,
  input  logic [1:0]             predecode_type           [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]   predecode_target_address [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]   seq_next_pc,
  output logic [FETCH_WIDTH-1:0] predict_dir_corrected,
  output logic [XLEN_BITS-1:0]   predict_next_fetch_address_corrected,
  output logic                   predecode_flush_enable
);

  logic [FETCH_WIDTH-1:0] taken, lane_uses_target;
  logic [FETCH_WIDTH-1:0] first_taken_onehot;
  logic                   any_taken, first_taken_uses_target;
  logic [XLEN_BITS-1:0]   first_taken_target;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      case (predecode_type[i])
        PREDECODE_BRANCH: taken[i] = predict_dir[i];
        PREDECODE_JALR:               taken[i] = 1'b1;
        PREDECODE_JAL:                taken[i] = 1'b1;
        default:                      taken[i] = 1'b0;
      endcase
      predict_dir_corrected[i] = taken[i];
      lane_uses_target[i]      = (predecode_type[i] == PREDECODE_BRANCH) ||
                                 (predecode_type[i] == PREDECODE_JAL);
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_first_taken (.req(taken), .onehot(first_taken_onehot), .any(any_taken));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_first_taken_target (
    .sel(first_taken_onehot), .data(predecode_target_address), .out(first_taken_target)
  );
  assign first_taken_uses_target = |(first_taken_onehot & lane_uses_target);

  always_comb begin
    if (!any_taken)                   predict_next_fetch_address_corrected = seq_next_pc;
    else if (first_taken_uses_target) predict_next_fetch_address_corrected = first_taken_target;
    else                              predict_next_fetch_address_corrected = predict_next_fetch_address;
    predecode_flush_enable = (predict_next_fetch_address != predict_next_fetch_address_corrected);
  end

endmodule

`default_nettype wire
