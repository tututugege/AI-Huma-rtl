// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (branch misprediction arbitration, early recovery); cmp_inst_age
`default_nettype none

module exu_ctrl_br_arb
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t                     fu_done [N_FU],
  output logic                         mispred,
  output logic [XLEN_BITS-1:0]         redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0]     redirect_rob_idx,
  output logic                         redirect_rob_flag,
  output logic [FTQ_IDX_WIDTH-1:0]     ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0]  ftq_offset,
  output logic [XLEN_BITS-1:0]         br_pc,
  output logic                         br_is_rvc
);

  localparam int NBR = BRU_NUM;
  localparam int DW  = XLEN_BITS + ROB_IDX_WIDTH + 1 + FTQ_IDX_WIDTH + FTQ_OFFSET_WIDTH + XLEN_BITS + 1;

  logic [NBR-1:0] resolved;
  logic [NBR-1:0] wrong;
  logic [NBR-1:0] oldest_onehot;
  logic [DW-1:0]  cand [NBR];
  logic [DW-1:0]  oldest_bits;

  for (genvar i = 0; i < NBR; i++) begin : g_bru
    localparam int FU = xc_kind_fu(XC_K_BR, i);
    logic [NBR-1:0] beaten_by;
    assign resolved[i] = fu_done[FU].complete;
    assign wrong[i]    = resolved[i] && fu_done[FU].mispred;
    assign cand[i]     = {fu_done[FU].diag_val, fu_done[FU].rob_idx, fu_done[FU].rob_flag, fu_done[FU].ftq_idx,
                          fu_done[FU].ftq_offset, fu_done[FU].pc, fu_done[FU].is_rvc};
    for (genvar j = 0; j < NBR; j++) begin : g_cmp
      if (j == i) begin : g_self
        assign beaten_by[j] = 1'b0;
      end else begin : g_other
        localparam bit TIE_TO_OTHER = (j < i);
        localparam int OTHER = xc_kind_fu(XC_K_BR, j);
        logic older;
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

  ttg_onehot_mux #(.N(NBR), .W(DW)) u_oldest (.sel(oldest_onehot), .data(cand), .out(oldest_bits));

  always_comb begin
    mispred = |wrong;
    {redirect_pc, redirect_rob_idx, redirect_rob_flag, ftq_idx, ftq_offset, br_pc, br_is_rvc} = oldest_bits;
  end

endmodule

`default_nettype wire
