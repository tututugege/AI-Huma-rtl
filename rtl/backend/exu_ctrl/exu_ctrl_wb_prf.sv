// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (bypass broadcast, INT write-back, LSU write-back to Prf)
`default_nettype none

// Write-back traffic to the Prf: the per-FU bypass bus and the 22 write-back entries
// (INT ports: the port winner; load/store-address ports: the Lsu write-back request).
module exu_ctrl_wb_prf
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t                  fu_done [N_FU],
  input  logic [ALU_NUM-1:0]        win_valid,       // INT ports 0..ALU_NUM-1
  input  xc_done_t                  win [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0]        win_is_csr,
  input  logic                      csr_re,          // exe2csr.re: a CSR read is in flight in the CSR slot
  input  logic [XLEN_BITS-1:0]               csr_rdata,
  input  xc_lsu_wb_t                ld_wb  [LSU_LOAD_WB_WIDTH],
  input  xc_lsu_wb_t                sta_wb [LSU_STA_COUNT],
  output logic [ISSUE_WIDTH-1:0] entry_valid,
  output logic [PRF_IDX_WIDTH-1:0]  entry_dest_preg [ISSUE_WIDTH],
  output logic [XLEN_BITS-1:0]               entry_result    [ISSUE_WIDTH],
  output logic [BR_MASK_WIDTH-1:0]  entry_br_mask   [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] entry_dest_en,
  output logic [XC_OP_W-1:0]        entry_op        [ISSUE_WIDTH],
  output logic [N_FU-1:0] bypass_valid,
  output logic [PRF_IDX_WIDTH-1:0]  bypass_dest_preg [N_FU],
  output logic [XLEN_BITS-1:0]               bypass_result    [N_FU],
  output logic [N_FU-1:0] bypass_dest_en
);

  // every completing FU is broadcast, whether or not it wins its port's write-back
  for (genvar f = 0; f < N_FU; f++) begin : g_bypass
    assign bypass_valid[f]     = fu_done[f].complete;
    assign bypass_dest_preg[f] = fu_done[f].dest_preg;
    assign bypass_result[f]    = fu_done[f].result;
    assign bypass_dest_en[f]   = fu_done[f].dest_en;
  end

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam bit IS_INT = (p >= IQ_ALU_PORT_BASE) && (p < IQ_ALU_PORT_BASE + ALU_NUM);
    localparam bit IS_LD  = (p >= IQ_LD_PORT_BASE) && (p < IQ_LD_PORT_BASE + LSU_LOAD_WB_WIDTH);
    localparam bit IS_STA = (p >= IQ_STA_PORT_BASE) && (p < IQ_STA_PORT_BASE + LSU_STA_COUNT);
    if (IS_INT) begin : g_int
      // Ref: int_res[] (valid only if dest_en); a CSR winner that reads takes the CSR read data
      assign entry_valid[p]     = win_valid[p] && win[p].dest_en;
      assign entry_dest_preg[p] = win[p].dest_preg;
      assign entry_result[p]    = (win_is_csr[p] && csr_re) ? csr_rdata : win[p].result;
      assign entry_br_mask[p]   = win[p].br_mask;
      assign entry_dest_en[p]   = win[p].dest_en;
      assign entry_op[p]        = win[p].op;
    end else if (IS_LD) begin : g_ld
      // Ref: lsu2exe.wb_req[i] (op is always LOAD: loads and SC)
      assign entry_valid[p]     = ld_wb[p-IQ_LD_PORT_BASE].valid;
      assign entry_dest_preg[p] = ld_wb[p-IQ_LD_PORT_BASE].dest_preg;
      assign entry_result[p]    = ld_wb[p-IQ_LD_PORT_BASE].result;
      assign entry_br_mask[p]   = ld_wb[p-IQ_LD_PORT_BASE].br_mask;
      assign entry_dest_en[p]   = ld_wb[p-IQ_LD_PORT_BASE].dest_en;
      assign entry_op[p]        = XC_OP_W'(XC_UOP_LOAD);
    end else if (IS_STA) begin : g_sta
      // Ref: lsu2exe.sta_wb_req[i] (op is always STA, never writes a register)
      assign entry_valid[p]     = sta_wb[p-IQ_STA_PORT_BASE].valid;
      assign entry_dest_preg[p] = '0;
      assign entry_result[p]    = sta_wb[p-IQ_STA_PORT_BASE].result;
      assign entry_br_mask[p]   = sta_wb[p-IQ_STA_PORT_BASE].br_mask;
      assign entry_dest_en[p]   = 1'b0;
      assign entry_op[p]        = XC_OP_W'(XC_UOP_STA);
    end else begin : g_none
      assign entry_valid[p]     = 1'b0;
      assign entry_dest_preg[p] = '0;
      assign entry_result[p]    = '0;
      assign entry_br_mask[p]   = '0;
      assign entry_dest_en[p]   = 1'b0;
      assign entry_op[p]        = '0;
    end
  end

endmodule

`default_nettype wire
