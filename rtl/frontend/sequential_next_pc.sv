// Ref: front-end/front_top.cpp  sequential_next_pc (78-96, CONFIG_FRONT_VALID_PREFIX_SEQ_NEXT = 1)
`default_nettype none

// Next sequential fetch pc after a fetch group: fetch_pc + 4 * (length of the leading run of valid lanes), cut back
// to the start of the next cache line when the run would cross a line boundary.
module sequential_next_pc import ttg_cfg_pkg::*; import front_pkg::*; (
  // clk / rst_n: required first ports of every top-level module (harness wrapper); this block is purely combinational
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,
  input  logic        rst_n,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] fetch_pc,
  input  logic [FETCH_WIDTH-1:0] inst_valid,
  output logic [XLEN_BITS-1:0] seq_next_pc
);

  localparam int PREFIX_W = $clog2(FETCH_WIDTH + 1);
  localparam logic [XLEN_BITS-1:0] LINE_MASK = ~(XLEN_BITS'(ICACHE_LINE_SIZE) - XLEN_BITS'(1));

  logic [FETCH_WIDTH-1:0]       lane_invalid;
  logic [FETCH_WIDTH-1:0]       first_invalid_onehot;
  logic                         any_invalid;
  logic [$clog2(FETCH_WIDTH)-1:0] first_invalid_idx;
  logic [PREFIX_W-1:0]          valid_prefix;   // number of leading valid lanes
  logic [XLEN_BITS-1:0]         group_end_pc;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) lane_invalid[i] = !inst_valid[i];
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_first_invalid (
    .req(lane_invalid), .onehot(first_invalid_onehot), .any(any_invalid));
  ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_first_invalid_idx (
    .onehot(first_invalid_onehot), .idx(first_invalid_idx));

  always_comb begin
    valid_prefix = any_invalid ? PREFIX_W'(first_invalid_idx) : PREFIX_W'(FETCH_WIDTH);
    group_end_pc = fetch_pc + XLEN_BITS'(valid_prefix) * XLEN_BITS'(INST_BYTES);
    // a group that runs past its cache line is cut at the line boundary
    seq_next_pc  = ((group_end_pc & LINE_MASK) != (fetch_pc & LINE_MASK)) ? (group_end_pc & LINE_MASK) : group_end_pc;
  end

endmodule

`default_nettype wire
