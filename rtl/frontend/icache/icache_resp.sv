// Ref: front-end/icache/ICacheTop.cpp  eval_true_glue
`default_nettype none

// Cuts the fetch group out of the 64-byte line answered by the I-cache: lane i takes word (pc[5:2] + i); lanes
// past the end of
// the line are invalid.  A page fault marks every lane valid + faulting with a NOP instruction.  An uncached
// answer is a
// single word in lane 0.
module icache_resp import icache_pkg::*; import ttg_cfg_pkg::*; (
  input  logic                 resp_valid,
  input  logic [31:0]          resp_pc,
  input  logic                 resp_page_fault,
  input  logic                 resp_single_word,
  input  logic [IC_LINE_W-1:0] resp_line,
  output logic [31:0]          fetch_pc,
  output logic [31:0]          fetch_group [FETCH_WIDTH],
  output logic                 page_fault_inst [FETCH_WIDTH],
  output logic                 inst_valid [FETCH_WIDTH]
);

  localparam logic [31:0] INST_NOP = 32'h0000_0013;
  logic [IC_WORD_IDX_W-1:0] base;
  assign base     = resp_pc[IC_OFF_W-1:2];
  assign fetch_pc = resp_valid ? resp_pc : 32'd0;

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

endmodule

`default_nettype wire
