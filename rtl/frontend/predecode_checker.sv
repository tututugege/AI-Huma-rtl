// Ref: front-end/predecode_checker.cpp  predecode_checker_comb
`default_nettype none

// Compare the BPU prediction with what predecode found in the instruction bytes.
//  - a lane is taken if it is jal/jalr, or a conditional branch the BPU predicted taken (non-branches: never taken);
//  - next fetch address = target of the first taken lane (jal / branch only; jalr keeps the BPU address),
//    or the sequential address when nothing is taken;
//  - flush when this differs from what the BPU predicted.
module predecode_checker import ttg_cfg_pkg::*; import front_pkg::*; (
  // clk / rst_n: required first ports of every top-level module (harness wrapper); this block is purely combinational
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,
  input  logic        rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        predict_dir                           [FETCH_WIDTH],
  input  logic [31:0] predict_next_fetch_address,
  input  logic [1:0]  predecode_type                        [FETCH_WIDTH],
  input  logic [31:0] predecode_target_address              [FETCH_WIDTH],
  input  logic [31:0] seq_next_pc,
  output logic        predict_dir_corrected                 [FETCH_WIDTH],
  output logic [31:0] predict_next_fetch_address_corrected,
  output logic        predecode_flush_enable
);

  logic [FETCH_WIDTH-1:0] taken;               // predict_dir_corrected as a vector
  logic [FETCH_WIDTH-1:0] first_taken_onehot;
  logic                   any_taken;
  logic [31:0]            target_of_lane [FETCH_WIDTH];  // direct target of each lane
  logic [FETCH_WIDTH-1:0] lane_uses_target;
  logic [31:0]            first_taken_target;
  logic                   first_taken_uses_target;

  // Ref: predecode_checker_comb, first loop (type -> corrected direction)
  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      case (predecode_type[i])
        PREDECODE_DIRECT_JUMP_NO_JAL: taken[i] = predict_dir[i];
        PREDECODE_JALR:               taken[i] = 1'b1;
        PREDECODE_JAL:                taken[i] = 1'b1;
        default:                      taken[i] = 1'b0;   // NON_BRANCH
      endcase
      predict_dir_corrected[i] = taken[i];
      // jal and conditional branches have a direct target; jalr keeps the BPU address
      lane_uses_target[i] = (predecode_type[i] == PREDECODE_DIRECT_JUMP_NO_JAL) || (predecode_type[i] == PREDECODE_JAL);
      target_of_lane[i]   = predecode_target_address[i];
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_first_taken (.req(taken), .onehot(first_taken_onehot), .any(any_taken));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(32)) u_first_taken_target (
    .sel(first_taken_onehot), .data(target_of_lane), .out(first_taken_target));
  assign first_taken_uses_target = |(first_taken_onehot & lane_uses_target);

  // Ref: predecode_checker_comb, second part (corrected next fetch address + flush)
  always_comb begin
    if (!any_taken)                   predict_next_fetch_address_corrected = seq_next_pc;
    else if (first_taken_uses_target) predict_next_fetch_address_corrected = first_taken_target;
    else                              predict_next_fetch_address_corrected = predict_next_fetch_address;
    predecode_flush_enable = (predict_next_fetch_address != predict_next_fetch_address_corrected);
  end

endmodule

`default_nettype wire
