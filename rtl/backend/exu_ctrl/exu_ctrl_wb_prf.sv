// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (bypass broadcast, INT write-back, LSU write-back to Prf)
`default_nettype none

// Write-back traffic to the Prf: the per-FU bypass bus and the register write-back bus of WB_LANES lanes (EXP-046, config.h WB_*):
// lanes WB_ALU_BASE.. the ALU port winners, WB_LD_BASE.. the Lsu load write-back requests, WB_FP_BASE.. the F/D port winners.
// The store-address / store-data / branch ports never write a register and have no lane (their completions go to the ROB only).
module exu_ctrl_wb_prf
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
  import fp_pkg::*;
(
  input  xc_done_t                  fu_done [N_FU],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only the ALU ports and the F/D ports have a write-back lane
  input  logic [ISSUE_WIDTH-1:0]    win_valid,       // ALU ports and F/D ports
  input  xc_done_t                  win [ISSUE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [ALU_NUM-1:0]        win_is_csr,
  input  logic                      csr_re,          // exe2csr.re: a CSR read is in flight in the CSR slot
  input  logic [XLEN_BITS-1:0]               csr_rdata,
  input  xc_lsu_wb_t                ld_wb  [LSU_LOAD_WB_WIDTH],
  output logic [WB_LANES-1:0]    entry_valid,
  output logic [PRF_IDX_WIDTH-1:0]  entry_dest_preg [WB_LANES],
  output logic [XLEN_BITS-1:0]               entry_result    [WB_LANES],
  output logic [FW-1:0]             entry_fresult   [WB_LANES],   // F/D: 64-bit result of an FP-register write
  output logic [BR_MASK_WIDTH-1:0]  entry_br_mask   [WB_LANES],
  output logic [WB_LANES-1:0]    entry_dest_en,
  output logic [XC_OP_W-1:0]        entry_op        [WB_LANES],
  output logic [N_FU-1:0] bypass_valid,
  output logic [PRF_IDX_WIDTH-1:0]  bypass_dest_preg [N_FU],
  output logic [XLEN_BITS-1:0]               bypass_result    [N_FU],
  output logic [FW-1:0]             bypass_fresult   [N_FU],
  output logic [N_FU-1:0] bypass_dest_en
);

  // every completing FU is broadcast, whether or not it wins its port's write-back
  for (genvar f = 0; f < N_FU; f++) begin : g_bypass
    assign bypass_valid[f]     = fu_done[f].complete;
    assign bypass_dest_preg[f] = fu_done[f].dest_preg;
    // the CSR FU's result is the CSR read data (muxed into the write-back entry below): a consumer that reads its
    // operand in the cycle the CSR instruction executes must see it on the bypass too
    if (f == CSR_FU) begin : g_csr_byp
      assign bypass_result[f]  = csr_re ? csr_rdata : fu_done[f].result;
    end else begin : g_other_byp
      assign bypass_result[f]  = fu_done[f].result;
    end
    assign bypass_fresult[f]   = fu_done[f].fresult;
    assign bypass_dest_en[f]   = fu_done[f].dest_en;
  end

  for (genvar l = 0; l < WB_LANES; l++) begin : g_lane
    localparam bit IS_LD = (l >= WB_LD_BASE) && (l < WB_FP_BASE);
    localparam bit IS_FP = l >= WB_FP_BASE;
    // issue port of an ALU / F/D lane (a load lane has none)
    localparam int P = IS_FP ? IQ_FP_PORT_BASE + (l - WB_FP_BASE) : IQ_ALU_PORT_BASE + (l - WB_ALU_BASE);
    if (IS_LD) begin : g_ld
      // Ref: lsu2exe.wb_req[i] (op is always LOAD: loads and SC)
      localparam int K = l - WB_LD_BASE;
      assign entry_valid[l]     = ld_wb[K].valid;
      assign entry_dest_preg[l] = ld_wb[K].dest_preg;
      assign entry_result[l]    = ld_wb[K].result;
      // flw: NaN-boxed (fld on rv64 returns the whole word)
      assign entry_fresult[l]   = fp_load_data(ld_wb[K].result, ld_wb[K].is_w);
      assign entry_br_mask[l]   = ld_wb[K].br_mask;
      assign entry_dest_en[l]   = ld_wb[K].dest_en;
      assign entry_op[l]        = XC_OP_W'(XC_UOP_LOAD);
    end else begin : g_win
      // Ref: int_res[] (valid only if dest_en); a CSR winner that reads takes the CSR read data
      assign entry_valid[l]     = win_valid[P] && win[P].dest_en;
      assign entry_dest_preg[l] = win[P].dest_preg;
      if (!IS_FP) begin : g_res_int
        assign entry_result[l]  = (win_is_csr[P] && csr_re) ? csr_rdata : win[P].result;
      end else begin : g_res_fp
        assign entry_result[l]  = win[P].result;
      end
      assign entry_fresult[l]   = win[P].fresult;
      assign entry_br_mask[l]   = win[P].br_mask;
      assign entry_dest_en[l]   = win[P].dest_en;
      assign entry_op[l]        = win[P].op;
    end
  end

endmodule

`default_nettype wire
