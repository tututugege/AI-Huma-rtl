// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (lrsc_unit: reservation killed by page fault / mispredict, br_mask cleared)
`default_nettype none

module lsu_lrsc
  import lsu_pkg::*;
(
  input  logic             valid_i,            // after comb_lsu2exe (SC consumed / LR armed)
  input  logic [31:0]      addr_i,
  input  logic [BRW-1:0]   br_i,
  input  logic             pf_clear,           // a load or store page fault (comb_tlb_in_*)
  input  logic             mispred,
  input  logic [BRW-1:0]   dec_br_mask,
  input  logic [BRW-1:0]   clear_mask,
  output logic             valid_o,
  output logic [31:0]      addr_o,
  output logic [BRW-1:0]   br_o
);

  logic alive;
  assign alive   = valid_i && !pf_clear && !(mispred && (br_i & dec_br_mask) != '0);
  assign valid_o = alive;
  assign addr_o  = addr_i;
  assign br_o    = alive ? br_i & ~clear_mask : br_i;

endmodule

`default_nettype wire
