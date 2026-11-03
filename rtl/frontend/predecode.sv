// Ref: front-end/predecode.cpp  predecode_comb; front_top.cpp:1624-1640 (8 lanes of one fetch group)
`default_nettype none

// Predecode of a whole fetch group: lane i sits at fetch_pc + 4*i.  Port adaptation only.
module predecode import ttg_cfg_pkg::*; import front_pkg::*; (
  // clk / rst_n: required first ports of every top-level module (harness wrapper); this block is purely combinational
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,
  input  logic        rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] fetch_pc,
  input  logic [31:0] inst                     [FETCH_WIDTH],
  input  logic        inst_valid               [FETCH_WIDTH],
  output logic [1:0]  predecode_type           [FETCH_WIDTH],
  output logic [31:0] predecode_target_address [FETCH_WIDTH]
);

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_lane
    predecode_lane u_lane (
      .pc                       (fetch_pc + 32'(i * INST_BYTES)),
      .inst                     (inst[i]),
      .inst_valid               (inst_valid[i]),
      .predecode_type           (predecode_type[i]),
      .predecode_target_address (predecode_target_address[i])
    );
  end

endmodule

`default_nettype wire
