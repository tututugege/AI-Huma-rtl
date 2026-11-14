// Ref: front-end/icache/ICacheTop.cpp  eval_true_glue
`default_nettype none

// Cuts the fetch group out of the 64-byte line answered by the I-cache: lane i takes word (pc[5:2] + i); lanes
// past the end of
// the line are invalid.  A page fault marks every lane valid + faulting with a NOP instruction.  An uncached
// answer is a
// single word in lane 0.
module icache_resp import icache_pkg::*; import ttg_cfg_pkg::*; (
  input  logic                 resp_valid,
  input  logic [XLEN_BITS-1:0]          resp_pc,
  input  logic                 resp_page_fault,
  input  logic                 resp_single_word,
  input  logic [IC_LINE_W-1:0] resp_line,
  output logic [XLEN_BITS-1:0]          fetch_pc,
  output logic [31:0]          fetch_group [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] page_fault_inst,
  output logic [FETCH_WIDTH-1:0] inst_valid
);

  localparam logic [31:0] INST_NOP = 32'h0000_0013;
  assign fetch_pc = resp_valid ? resp_pc : '0;

  if (RVC_ENABLE == 0) begin : g_word
    logic [IC_WORD_IDX_W-1:0] base;
    assign base = resp_pc[IC_OFF_W-1:2];
    for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_lane
      logic [IC_WORD_IDX_W:0] widx;
      logic in_line, lane_on;
      assign widx    = {1'b0, base} + (IC_WORD_IDX_W+1)'(i);
      assign in_line = !widx[IC_WORD_IDX_W];
      assign lane_on = resp_valid && (resp_single_word ? (i == 0) : in_line);
      assign inst_valid[i]       = lane_on;
      assign page_fault_inst[i]  = lane_on && resp_page_fault;
      assign fetch_group[i]      = (lane_on && !resp_page_fault)
                                   ? resp_line[IC_WORD_W * widx[IC_WORD_IDX_W-1:0] +: IC_WORD_W]
                                                                  : INST_NOP;
    end
  end else begin : g_half
    // RVC=1: lane i is the 32-bit window that starts at halfword (pc[5:1] + i) of the line; a lane is on while its
    // halfword is inside the line.  The window of the line's last halfword has no upper half (0): a 32-bit instruction
    // that starts there is carried to the next group by the front end.  An uncached answer is one word = two slots.
    localparam int IC_HALVES = IC_LINE_W / 16;
    logic [15:0] half [IC_HALVES + 1];
    for (genvar h = 0; h < IC_HALVES; h++) begin : g_h
      assign half[h] = resp_line[16 * h +: 16];
    end
    assign half[IC_HALVES] = 16'h0;
    logic [IC_OFF_W-2:0] base;
    assign base = resp_pc[IC_OFF_W-1:1];
    localparam int HI_W = $clog2(IC_HALVES + 1);
    logic [15:0] upper [FETCH_WIDTH];
    for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_lane
      logic [IC_OFF_W-1:0] hidx;
      logic [HI_W-1:0]     h0, h1;
      logic in_line, lane_on;
      assign hidx    = {1'b0, base} + IC_OFF_W'(i);
      assign in_line = !hidx[IC_OFF_W-1];
      // an uncached answer is one word = two halfword slots (the window of the second one has no upper half)
      assign lane_on = resp_valid && (resp_single_word ? (i < 2) : in_line);
      assign h0      = HI_W'(hidx[IC_OFF_W-2:0]);
      assign h1      = h0 + HI_W'(1);
      assign inst_valid[i]       = lane_on;
      assign page_fault_inst[i]  = lane_on && resp_page_fault;
      assign upper[i]            = (resp_single_word && i == 1) ? 16'h0 : half[h1];
      assign fetch_group[i]      = (lane_on && !resp_page_fault) ? {upper[i], half[h0]} : INST_NOP;
    end
  end

endmodule

`default_nettype wire
