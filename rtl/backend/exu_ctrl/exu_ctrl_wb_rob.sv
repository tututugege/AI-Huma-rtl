// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (exu2rob from FU winners and from Lsu write-back)
`default_nettype none

// Completion reports to the Rob (packed xc_rob_wb_t per ROB_WB channel).
module exu_ctrl_wb_rob
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                     flush,
  input  logic                     mispred,
  input  logic [ROB_IDX_WIDTH-1:0] kill_rob_idx,
  input  logic                     kill_rob_flag,
  input  logic [ISSUE_WIDTH-1:0]   win_valid,
  input  xc_done_t                 win    [ISSUE_WIDTH],
  input  xc_lsu_wb_t               ld_wb  [LSU_LOAD_WB_WIDTH],
  input  xc_lsu_wb_t               sta_wb [LSU_STA_COUNT],
  output xc_rob_wb_t               wb     [ROB_WB_WIDTH]
);

  for (genvar c = 0; c < ROB_WB_WIDTH; c++) begin : g_ch
    localparam bit IS_ALU = (c >= ROB_WB_ALU_BASE) && (c < ROB_WB_ALU_BASE + ALU_NUM);
    localparam bit IS_LD  = (c >= ROB_WB_LD_BASE)  && (c < ROB_WB_LD_BASE  + LSU_LOAD_WB_WIDTH);
    localparam bit IS_STA = (c >= ROB_WB_STA_BASE) && (c < ROB_WB_STA_BASE + LSU_STA_COUNT);
    localparam bit IS_STD = (c >= ROB_WB_STD_BASE) && (c < ROB_WB_STD_BASE + LSU_SDU_COUNT);
    localparam bit IS_BR  = (c >= ROB_WB_BR_BASE)  && (c < ROB_WB_BR_BASE  + BRU_NUM);
    localparam int P = IS_ALU ? (IQ_ALU_PORT_BASE + (c - ROB_WB_ALU_BASE))
                     : IS_STD ? (IQ_STD_PORT_BASE + (c - ROB_WB_STD_BASE))
                     : IS_BR  ? (IQ_BR_PORT_BASE  + (c - ROB_WB_BR_BASE))
                              : (IQ_FP_PORT_BASE  + (c - ROB_WB_FP_BASE));
    if (IS_LD || IS_STA) begin : g_lsu
      localparam int I = IS_LD ? (c - ROB_WB_LD_BASE) : (c - ROB_WB_STA_BASE);
      logic dropped;
      assign dropped = flush || xc_killed(mispred, IS_LD ? ld_wb[I].rob_idx : sta_wb[I].rob_idx,
                                          IS_LD ? ld_wb[I].rob_flag : sta_wb[I].rob_flag, kill_rob_idx, kill_rob_flag);
      assign wb[c] = '{
        valid:            (IS_LD ? ld_wb[I].valid : sta_wb[I].valid) && !dropped,
        rob_idx:          IS_LD ? ld_wb[I].rob_idx : sta_wb[I].rob_idx,
        op:               IS_LD ? dis_pkg::UOP_LOAD : dis_pkg::UOP_STA,
        result:           IS_LD ? ld_wb[I].result : sta_wb[I].result,
        br_taken:         1'b0,
        page_fault_load:  IS_LD && ld_wb[I].page_fault_load,
        page_fault_store: IS_LD ? ld_wb[I].page_fault_store : sta_wb[I].page_fault_store,
        rob_defer:        IS_LD && ld_wb[I].rob_defer,
        flush_pipe:       IS_LD && ld_wb[I].flush_pipe,
        fflags:           '0,
        illegal:          1'b0
      };
    end else begin : g_fu
      assign wb[c] = '{
        valid:            win_valid[P],
        rob_idx:          win[P].rob_idx,
        op:               win[P].op,
        result:           '0,
        br_taken:         IS_BR && win[P].br_taken,
        page_fault_load:  1'b0,
        page_fault_store: 1'b0,
        rob_defer:        1'b0,
        flush_pipe:       1'b0,
        fflags:           win[P].fflags,
        illegal:          win[P].illegal
      };
    end
  end

endmodule

`default_nettype wire
