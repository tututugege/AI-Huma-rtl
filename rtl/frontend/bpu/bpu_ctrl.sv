// Ref: front-end/BPU/BPU.h  BPU_TOP::bpu_pre_read_req_comb, bpu_core_comb_calc (pc_reg update)
`default_nettype none

// Fetch-group generation: base pc, the 8 lane pcs and which of them lie before the end of the (64-byte) cache line
// group, the control outputs and the fetch pc register.
//   base     = refetch ? refetch_address : pc
//   boundary = base+32, cut to the line start when base+32 crosses a 64-byte line
//   lane i   : pc_i = base + 4i, valid if pc_i < boundary (32-bit unsigned compare, like the C++), bank = pc_i[4:2]
//   going_to_do_pred = icache_read_ready || refetch        (pc_can_send_to_icache is constant 1)
//   pc next  = refetch ? refetch_address : going_to_do_pred ? next_pc : pc
module bpu_ctrl import bpu_pkg::*; import ttg_cfg_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic [31:0]         refetch_address,
  input  logic                icache_read_ready,
  input  logic [31:0]         next_pc,              // predicted next fetch address of this group
  output logic [31:0]         pred_base,
  output logic [31:0]         boundary,
  output logic                lane_valid [NLANE],
  output logic [31:0]         lane_pc    [NLANE],
  output logic                going_to_do_pred,
  output logic                icache_read_valid,
  output logic                ptab_write_enable
);

  localparam logic [31:0] LINE_MASK = ~32'(ICACHE_LINE_SIZE - 1);
  localparam logic [31:0] GROUP_BYTES = 32'(FETCH_WIDTH * 4);

  logic [31:0] pc_q;
  logic [31:0] pc_d;
  logic [31:0] base_plus;

  always_comb begin
    pred_base         = refetch ? refetch_address : pc_q;
    base_plus         = pred_base + GROUP_BYTES;
    boundary          = ((pred_base & LINE_MASK) != (base_plus & LINE_MASK)) ? (base_plus & LINE_MASK) : base_plus;
    for (int i = 0; i < NLANE; i++) begin
      lane_pc[i]    = pred_base + 32'(4 * i);
      lane_valid[i] = (lane_pc[i] < boundary);
    end
    going_to_do_pred  = icache_read_ready || refetch;
    icache_read_valid = !refetch;
    ptab_write_enable = going_to_do_pred && !refetch;
    pc_d              = refetch ? refetch_address : (going_to_do_pred ? next_pc : pc_q);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) pc_q <= 32'd0;      // RESET_PC
    else        pc_q <= pc_d;
  end

endmodule

`default_nettype wire
