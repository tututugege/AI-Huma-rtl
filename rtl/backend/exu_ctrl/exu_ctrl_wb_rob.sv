// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (exu2rob from FU winners and from Lsu write-back)
`default_nettype none

// Completion reports to the Rob. Only the fields a given port's reader uses are produced (the others are 0):
//   rob_idx, op        all ports
//   diag_val, result   load/store-address ports (6..13) and diag_val also branch ports (Rob::comb_complete)
//   mispred, br_taken  branch ports; page_fault_load/store: load/store-address ports
module exu_ctrl_wb_rob
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                      flush,
  input  logic                      mispred,
  input  logic [BR_MASK_WIDTH-1:0]  kill_mask,
  // winners of the load/store-address ports (6..13) are never reported from here: those report Lsu write-back
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [ISSUE_WIDTH-1:0]    win_valid,
  /* verilator lint_on UNUSEDSIGNAL */
  input  xc_done_t                  win [ISSUE_WIDTH],
  input  xc_lsu_wb_t                ld_wb  [LSU_LOAD_WB_WIDTH],
  input  xc_lsu_wb_t                sta_wb [LSU_STA_COUNT],
  output logic [ISSUE_WIDTH-1:0] valid,
  output logic [ROB_IDX_WIDTH-1:0]  rob_idx   [ISSUE_WIDTH],
  output logic [XC_OP_W-1:0]        op        [ISSUE_WIDTH],
  output logic [XLEN_BITS-1:0]               diag_val  [ISSUE_WIDTH],
  output logic [XLEN_BITS-1:0]               result    [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] br_mispred,
  output logic                      br_taken  [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] page_fault_load,
  output logic [ISSUE_WIDTH-1:0] page_fault_store,
  output logic [ISSUE_WIDTH-1:0] rob_defer,
  output logic [ISSUE_WIDTH-1:0] flush_pipe
);

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam bit IS_LD  = (p >= IQ_LD_PORT_BASE) && (p < IQ_LD_PORT_BASE + LSU_LOAD_WB_WIDTH);
    localparam bit IS_STA = (p >= IQ_STA_PORT_BASE) && (p < IQ_STA_PORT_BASE + LSU_STA_COUNT);
    localparam bit IS_BR  = (p >= IQ_BR_PORT_BASE) && (p < IQ_BR_PORT_BASE + BRU_NUM);
    if (IS_LD || IS_STA) begin : g_lsu
      // write-back of a load / SC / store-address: dropped when flushed or killed by the mispredicted branch
      localparam int I = IS_LD ? (p - IQ_LD_PORT_BASE) : (p - IQ_STA_PORT_BASE);
      logic dropped;
      assign dropped = flush || xc_killed(mispred, IS_LD ? ld_wb[I].br_mask : sta_wb[I].br_mask, kill_mask);
      assign valid[p]            = (IS_LD ? ld_wb[I].valid : sta_wb[I].valid) && !dropped;
      assign rob_idx[p]          = IS_LD ? ld_wb[I].rob_idx : sta_wb[I].rob_idx;
      assign op[p]               = IS_LD ? XC_OP_W'(XC_UOP_LOAD) : XC_OP_W'(XC_UOP_STA);
      assign diag_val[p]         = IS_LD ? ld_wb[I].diag_val : sta_wb[I].diag_val;
      assign result[p]           = IS_LD ? ld_wb[I].result : sta_wb[I].result;
      assign br_mispred[p]       = 1'b0;
      assign br_taken[p]         = 1'b0;
      assign page_fault_load[p]  = IS_LD && ld_wb[I].page_fault_load;
      assign page_fault_store[p] = IS_LD ? ld_wb[I].page_fault_store : sta_wb[I].page_fault_store;
      assign rob_defer[p]        = IS_LD && ld_wb[I].rob_defer;
      assign flush_pipe[p]       = IS_LD && ld_wb[I].flush_pipe;
    end else begin : g_fu
      // functional-unit completion (never flushed, see notes 4.2-1)
      assign valid[p]            = win_valid[p];
      assign rob_idx[p]          = win[p].rob_idx;
      assign op[p]               = win[p].op;
      assign diag_val[p]         = IS_BR ? win[p].diag_val : '0;
      assign result[p]           = '0;
      assign br_mispred[p]       = IS_BR && win[p].mispred;
      assign br_taken[p]         = IS_BR && win[p].br_taken;
      assign page_fault_load[p]  = 1'b0;
      assign page_fault_store[p] = 1'b0;
      assign rob_defer[p]        = 1'b0;
      assign flush_pipe[p]       = 1'b0;
    end
  end

endmodule

`default_nettype wire
