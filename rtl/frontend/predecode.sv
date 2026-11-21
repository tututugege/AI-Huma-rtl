// Ref: front-end/predecode.cpp  predecode_comb; front_top.cpp (FETCH_WIDTH lanes of one fetch group)
`default_nettype none

// Predecode of a whole fetch group with per-lane PCs (supporting paired A+B non-contiguous blocks).
module predecode import ttg_cfg_pkg::*; import front_pkg::*; (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,
  input  logic        rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] slot_pc                  [FETCH_WIDTH],
  input  logic [31:0]          inst                     [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] inst_valid,
  output logic [1:0]           predecode_type           [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0] predecode_target_address [FETCH_WIDTH]
);

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_lane
    predecode_lane u_lane (
      .pc                       (slot_pc[i]),
      .inst                     (inst[i]),
      .inst_valid               (inst_valid[i]),
      .predecode_type           (predecode_type[i]),
      .predecode_target_address (predecode_target_address[i])
    );
  end

endmodule

`default_nettype wire
