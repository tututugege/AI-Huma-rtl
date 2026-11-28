// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (INT write-back, LSU write-back to Prf)
`default_nettype none

// Write-back traffic to the Prf: WB_LANES packed entries (ALU winners, LSU load WB, F/D winners).
module exu_ctrl_wb_prf
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
  import fp_pkg::*;
(
  input  logic [ISSUE_WIDTH-1:0] win_valid,
  input  xc_done_t               win [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0]     win_is_csr,
  input  logic                   csr_re,
  input  logic [XLEN_BITS-1:0]   csr_rdata,
  input  xc_lsu_wb_t             ld_wb [LSU_LOAD_WB_WIDTH],
  output xc_prf_wb_t             wb    [WB_LANES]
);

  for (genvar l = 0; l < WB_LANES; l++) begin : g_lane
    localparam bit IS_LD = (l >= WB_LD_BASE) && (l < WB_FP_BASE);
    localparam bit IS_FP = l >= WB_FP_BASE;
    localparam int P = IS_FP ? IQ_FP_PORT_BASE + (l - WB_FP_BASE) : IQ_ALU_PORT_BASE + (l - WB_ALU_BASE);
    if (IS_LD) begin : g_ld
      localparam int K = l - WB_LD_BASE;
      assign wb[l] = '{
        valid:     ld_wb[K].valid,
        dest_preg: ld_wb[K].dest_preg,
        result:    ld_wb[K].result,
        fresult:   fp_load_data(ld_wb[K].result, ld_wb[K].is_w),
        rob_idx:   ld_wb[K].rob_idx,
        rob_flag:  ld_wb[K].rob_flag,
        dest_en:   ld_wb[K].dest_en,
        op:        dis_pkg::UOP_LOAD
      };
    end else begin : g_win
      assign wb[l] = '{
        valid:     win_valid[P] && win[P].dest_en,
        dest_preg: win[P].dest_preg,
        result:    (!IS_FP && win_is_csr[P] && csr_re) ? csr_rdata : win[P].result,
        fresult:   win[P].fresult,
        rob_idx:   win[P].rob_idx,
        rob_flag:  win[P].rob_flag,
        dest_en:   win[P].dest_en,
        op:        win[P].op
      };
    end
  end

endmodule

`default_nettype wire
