// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_flush: LDQ part -- rob flush, branch mispredict kill, br_mask clear)
`default_nettype none

module lsu_flush_ld
  import lsu_pkg::*;
(
  input  logic             flush,
  input  logic             mispred,
  input  logic [BRW-1:0]   dec_br_mask,
  input  logic [BRW-1:0]   clear_mask,
  input  ld_state_t        ld_st_i      [LQ],
  input  ld_state_t        ld_st_q      [LQ],     // cycle-start state: selects the entries whose br_mask is cleared
  input  logic [BRW-1:0]   ld_br_mask_i [LQ],
  output ld_state_t        ld_st_o      [LQ],
  output logic [LQ-1:0]    ld_empty_o,            // final state == Empty (used to invalidate queue entries)
  output logic [BRW-1:0]   ld_br_mask_o [LQ]
);

  for (genvar e = 0; e < LQ; e++) begin : g_entry
    ld_state_t after_flush;
    logic      killed;
    assign after_flush   = flush ? LD_EMPTY : ld_st_i[e];
    assign killed        = mispred && after_flush != LD_EMPTY && (ld_br_mask_i[e] & dec_br_mask) != '0;
    assign ld_st_o[e]    = killed ? LD_EMPTY : after_flush;
    assign ld_empty_o[e] = ld_st_o[e] == LD_EMPTY;
    assign ld_br_mask_o[e] = ld_st_q[e] != LD_EMPTY ? ld_br_mask_i[e] & ~clear_mask : ld_br_mask_i[e];
  end

endmodule

`default_nettype wire
