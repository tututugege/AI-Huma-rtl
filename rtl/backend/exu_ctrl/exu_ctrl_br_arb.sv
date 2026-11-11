// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (branch misprediction arbitration, early recovery); cmp_inst_age
`default_nettype none

// All resolved branches of this cycle release their tag (clear_mask); the oldest mispredicted one redirects.
module exu_ctrl_br_arb
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t                     fu_done [N_FU],
  output logic [BR_MASK_WIDTH-1:0]     clear_mask,
  output logic                         mispred,
  output logic [XLEN_BITS-1:0]                  redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0]     redirect_rob_idx,
  output logic [BR_TAG_WIDTH-1:0]      br_id,
  output logic [FTQ_IDX_WIDTH-1:0]     ftq_idx,
  output logic [XLEN_BITS-1:0]                  br_pc
);

  localparam int NBR = BRU_NUM;
  // {diag_val, rob_idx, br_id, ftq_idx, pc}
  localparam int DW  = XLEN_BITS + ROB_IDX_WIDTH + BR_TAG_WIDTH + FTQ_IDX_WIDTH + XLEN_BITS;

  logic [NBR-1:0] resolved;          // BRU produced a result (it is never flushed: see notes 4.2-1)
  logic [NBR-1:0] wrong;             // resolved and mispredicted
  logic [NBR-1:0] oldest_onehot;     // the oldest mispredicted branch (ties: lowest BRU index, as the sequential scan)
  logic [BR_MASK_WIDTH-1:0] tag_bits [NBR];
  logic [DW-1:0]  cand [NBR];
  logic [DW-1:0]  oldest_bits;

  for (genvar i = 0; i < NBR; i++) begin : g_bru
    localparam int FU = xc_kind_fu(XC_K_BR, i);
    logic [NBR-1:0] beaten_by;       // other mispredicted branches that win against branch i
    assign resolved[i] = fu_done[FU].complete;
    assign wrong[i]    = resolved[i] && fu_done[FU].mispred;
    assign cand[i]     = {fu_done[FU].diag_val, fu_done[FU].rob_idx, fu_done[FU].br_id, fu_done[FU].ftq_idx,
                          fu_done[FU].pc};
    assign tag_bits[i] = resolved[i] ? (BR_MASK_WIDTH'(1) << fu_done[FU].br_id) : '0;
    for (genvar j = 0; j < NBR; j++) begin : g_cmp
      if (j == i) begin : g_self
        assign beaten_by[j] = 1'b0;
      end else begin : g_other
        localparam bit TIE_TO_OTHER = (j < i);
        localparam int OTHER = xc_kind_fu(XC_K_BR, j);
        logic older;       // the other branch is older than this one
        logic same_age;
        assign older    = xc_older(fu_done[OTHER].rob_flag, fu_done[OTHER].rob_idx,
                                   fu_done[FU].rob_flag, fu_done[FU].rob_idx);
        assign same_age = (fu_done[FU].rob_flag == fu_done[OTHER].rob_flag)
                          && (fu_done[FU].rob_idx == fu_done[OTHER].rob_idx);
        assign beaten_by[j] = wrong[j] && (older || (TIE_TO_OTHER && same_age));
      end
    end
    assign oldest_onehot[i] = wrong[i] && (beaten_by == '0);
  end

  ttg_onehot_mux #(.N(NBR), .W(BR_MASK_WIDTH)) u_clear_or (.sel('1), .data(tag_bits), .out(clear_mask));
  ttg_onehot_mux #(.N(NBR), .W(DW)) u_oldest (.sel(oldest_onehot), .data(cand), .out(oldest_bits));

  always_comb begin
    mispred = |wrong;
    {redirect_pc, redirect_rob_idx, br_id, ftq_idx, br_pc} = oldest_bits;
  end

endmodule

`default_nettype wire
