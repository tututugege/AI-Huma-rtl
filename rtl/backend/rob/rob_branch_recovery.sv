// Ref: back-end/Rob.cpp  class Rob  (comb_branch: invalidate everything younger than dec_bcast.redirect_rob_idx)
`default_nettype none

module rob_branch_recovery
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                      recover,            // mispred && !flush
  input  logic [ROB_IDX_WIDTH-1:0]  redirect_rob_idx,
  input  logic [ROB_LINE_IDX_W-1:0] enq_ptr,            // old tail line (registered value)
  output logic [ROB_LINE_NUM-1:0]   branch_clr [ROB_BANK_NUM],  // slot is younger than the redirecting branch
  output logic [ROB_LINE_NUM-1:0]   mark_last  [ROB_BANK_NUM]   // slot is the redirecting branch
);

  logic [ROB_LINE_IDX_W-1:0] redirect_line;
  logic [ROB_BANK_IDX_W-1:0] redirect_bank;
  logic [ROB_LINE_IDX_W-1:0] first_younger_line;  // line after the redirect line
  logic [ROB_LINE_IDX_W-1:0] younger_span;        // number of whole lines between redirect line and the old tail
  logic [ROB_BANK_NUM-1:0]   younger_bank;        // banks after the redirecting branch inside its own line

  assign redirect_bank      = redirect_rob_idx[ROB_BANK_IDX_W-1:0];
  assign redirect_line      = redirect_rob_idx[ROB_IDX_WIDTH-1:ROB_BANK_IDX_W];
  assign first_younger_line = rob_line_inc(redirect_line);
  assign younger_span       = rob_line_dist(first_younger_line, enq_ptr);

  always_comb begin
    for (int b = 0; b < ROB_BANK_NUM; b++) younger_bank[b] = b > int'(redirect_bank);
  end

  // Ref: Rob::comb_branch  (the redirect line's younger banks, then every whole line up to but excluding the old tail)
  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_bank
    for (genvar l = 0; l < ROB_LINE_NUM; l++) begin : g_line
      logic in_redirect_line;
      logic in_younger_lines;
      assign in_redirect_line = (redirect_line == ROB_LINE_IDX_W'(l));
      assign in_younger_lines = rob_line_dist(first_younger_line, ROB_LINE_IDX_W'(l)) < younger_span;
      assign branch_clr[b][l] = recover && ((in_redirect_line && younger_bank[b]) || in_younger_lines);
      assign mark_last[b][l]  = recover && in_redirect_line && (ROB_BANK_IDX_W'(b) == redirect_bank);
    end
  end

endmodule

`default_nettype wire
