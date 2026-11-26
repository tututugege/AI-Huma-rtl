// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (exu2rob from FU winners and from Lsu write-back)
`default_nettype none

// Completion reports to the Rob (packed xc_rob_wb_t per issue port).
module exu_ctrl_wb_rob
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                     flush,
  input  logic                     mispred,
  input  logic [ROB_IDX_WIDTH-1:0] kill_rob_idx,
  input  logic                     kill_rob_flag,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: load/STA ports report from LSU WB instead of win[]
  input  logic [ISSUE_WIDTH-1:0]   win_valid,
  input  xc_done_t                 win    [ISSUE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  xc_lsu_wb_t               ld_wb  [LSU_LOAD_WB_WIDTH],
  input  xc_lsu_wb_t               sta_wb [LSU_STA_COUNT],
  output xc_rob_wb_t               wb     [ISSUE_WIDTH]
);

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam bit IS_LD  = (p >= IQ_LD_PORT_BASE) && (p < IQ_LD_PORT_BASE + LSU_LOAD_WB_WIDTH);
    localparam bit IS_STA = (p >= IQ_STA_PORT_BASE) && (p < IQ_STA_PORT_BASE + LSU_STA_COUNT);
    localparam bit IS_BR  = (p >= IQ_BR_PORT_BASE) && (p < IQ_BR_PORT_BASE + BRU_NUM);
    if (IS_LD || IS_STA) begin : g_lsu
      localparam int I = IS_LD ? (p - IQ_LD_PORT_BASE) : (p - IQ_STA_PORT_BASE);
      logic dropped;
      assign dropped = flush || xc_killed(mispred, IS_LD ? ld_wb[I].rob_idx : sta_wb[I].rob_idx,
                                          IS_LD ? ld_wb[I].rob_flag : sta_wb[I].rob_flag, kill_rob_idx, kill_rob_flag);
      assign wb[p] = '{
        valid:            (IS_LD ? ld_wb[I].valid : sta_wb[I].valid) && !dropped,
        rob_idx:          IS_LD ? ld_wb[I].rob_idx : sta_wb[I].rob_idx,
        op:               IS_LD ? XC_OP_W'(XC_UOP_LOAD) : XC_OP_W'(XC_UOP_STA),
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
      assign wb[p] = '{
        valid:            win_valid[p],
        rob_idx:          win[p].rob_idx,
        op:               win[p].op,
        result:           '0,
        br_taken:         IS_BR && win[p].br_taken,
        page_fault_load:  1'b0,
        page_fault_store: 1'b0,
        rob_defer:        1'b0,
        flush_pipe:       1'b0,
        fflags:           win[p].fflags,
        illegal:          win[p].illegal
      };
    end
  end

endmodule

`default_nettype wire
