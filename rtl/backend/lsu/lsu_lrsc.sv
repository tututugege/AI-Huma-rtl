// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (lrsc_unit: LR/SC reservation)
`default_nettype none

// LR/SC reservation register.  Rule chain of a cycle: F (SC consumes / LR arms, in lsu_wb_stq/lsu_wb_ldq)
// -> I (page fault of a load or store clears) -> L (mispredict with matching br_mask clears; clear_mask clears bits).
module lsu_lrsc
  import lsu_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  output logic             valid_q,            // cur.lrsc_unit (SC verdict of this cycle uses these)
  output logic [31:0]      addr_q,
  output logic [BRW-1:0]   br_q,
  input  logic             valid_i,            // after comb_lsu2exe (SC consumed / LR armed)
  input  logic [31:0]      addr_i,
  input  logic [BRW-1:0]   br_i,
  input  logic             pf_clear,           // a load or store page fault (comb_tlb_in_*)
  input  logic             mispred,
  input  logic [BRW-1:0]   dec_br_mask,
  input  logic [BRW-1:0]   clear_mask
);
  logic alive;
  assign alive = valid_i && !pf_clear && !(mispred && (br_i & dec_br_mask) != '0);

  always_ff @(posedge clk) begin
    if (!rst_n) valid_q <= 1'b0;
    else        valid_q <= alive;
    addr_q <= addr_i;
    br_q   <= alive ? br_i & ~clear_mask : br_i;
  end
endmodule

`default_nettype wire
