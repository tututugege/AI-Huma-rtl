// Ref: back-end/Rob.cpp  class Rob  (rob_is_complete/flush_inst/fence_inst/wfi classification of the head line)
`default_nettype none

module rob_head_class
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  rob_entry_t               head_uop [ROB_BANK_NUM],
  output logic [ROB_BANK_NUM-1:0]  is_complete,
  output logic [ROB_BANK_NUM-1:0]  is_flush,
  output logic [ROB_BANK_NUM-1:0]  is_fence,
  output logic [ROB_BANK_NUM-1:0]  is_wfi
);

  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_bank
    assign is_complete[b] = rob_is_complete(head_uop[b]);
    assign is_flush[b]    = rob_is_flush_inst(head_uop[b]);
    assign is_fence[b]    = rob_is_fence_inst(head_uop[b]);
    assign is_wfi[b]      = rob_is_wfi(head_uop[b]);
  end

endmodule

`default_nettype wire
