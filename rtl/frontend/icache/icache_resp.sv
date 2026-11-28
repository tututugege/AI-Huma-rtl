// Ref: front-end/icache/ICacheTop.cpp  eval_true_glue
`default_nettype none

// Cuts the fetch group out of the 64-byte line answered by the I-cache (RVC: halfword slots).  Lane i is the halfword
// (pc[5:1] + i) of the line; a lane is on while that halfword is inside the line.  The 32-bit window of lane i is
// {lane i+1, lane i} (the front end assembles it), so only one upper halfword is given: the one above lane 15
// (0 when lane 15 is off, i.e. the group ends at the end of the line).  An uncached answer is one word = two lanes.
// A page fault marks every lane on + faulting with the low half of a NOP; an off lane is the low half of a NOP too.
module icache_resp import icache_pkg::*; import ttg_cfg_pkg::*; (
  input  logic                   resp_valid,
  input  logic [XLEN_BITS-1:0]   resp_pc,
  input  logic                   resp_page_fault,
  input  logic                   resp_single_word,
  input  logic [IC_LINE_W-1:0]   resp_line,
  output logic [XLEN_BITS-1:0]   fetch_pc,
  output logic [15:0]            fetch_half [FETCH_WIDTH],
  output logic [15:0]            fetch_up16,       // halfword above lane 15 (0 unless lane 15 is on, no fault)
  output logic [FETCH_WIDTH-1:0] page_fault_inst,
  output logic [FETCH_WIDTH-1:0] inst_valid
);

  localparam logic [15:0] INST_NOP_LO = 16'h0013;
  localparam int          IC_HALVES   = IC_LINE_W / 16;
  localparam int          HI_W        = $clog2(IC_HALVES + 1);

  assign fetch_pc = resp_valid ? resp_pc : '0;

  logic [15:0]         half [IC_HALVES + 1];
  logic [IC_OFF_W-2:0] base;
  for (genvar h = 0; h < IC_HALVES; h++) begin : g_h
    assign half[h] = resp_line[16 * h +: 16];
  end
  assign half[IC_HALVES] = 16'h0;   // above the last halfword of the line
  assign base = resp_pc[IC_OFF_W-1:1];

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_lane
    logic [IC_OFF_W-1:0] hidx;
    logic                in_line, lane_on;
    assign hidx    = {1'b0, base} + IC_OFF_W'(i);
    assign in_line = !hidx[IC_OFF_W-1];
    assign lane_on = resp_valid && (resp_single_word ? (i < 2) : in_line);
    assign inst_valid[i]      = lane_on;
    assign page_fault_inst[i] = lane_on && resp_page_fault;
    assign fetch_half[i]      = (lane_on && !resp_page_fault) ? half[HI_W'(hidx[IC_OFF_W-2:0])] : INST_NOP_LO;
  end

  // lane 15 on => base <= 16, so base + 16 <= IC_HALVES (32 = the 0 above the line)
  logic [HI_W-1:0] up_idx;
  assign up_idx     = HI_W'(base) + HI_W'(FETCH_WIDTH);
  assign fetch_up16 = (inst_valid[FETCH_WIDTH-1] && !resp_page_fault) ? half[up_idx] : 16'h0;

endmodule

`default_nettype wire
