// Ref: back-end/Ren.cpp  class Ren  Ren::comb_fire (commit part)
`default_nettype none

// Which ROB commit slots give their old physical register back / update the arch RAT, and how many
// slots before each one do the same (write offset into the free list).
module ren_commit_filter
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic [C-1:0]                 commit_valid,
  input  logic [C-1:0]                 commit_dest_en,
  input  logic [C-1:0]                 commit_page_fault_inst,
  input  logic [C-1:0]                 commit_page_fault_load,
  input  logic [C-1:0]                 commit_page_fault_store,
  input  logic [C-1:0]                 commit_illegal_inst,
  input  logic [INST_TYPE_WIDTH-1:0]   commit_inst_type [C],
  input  logic                         rob_interrupt,
  output logic [C-1:0]                 reclaim,       // commit slot retires a dest and is not an exception/interrupt
  output logic [CW-1:0]                rank [C],      // number of reclaiming slots before this one
  output logic [CW-1:0]                total          // number of reclaiming slots
);

  logic [C-1:0] is_exception;

  for (genvar k = 0; k < C; k++) begin : g_slot
    logic [C-1:0] before_mask;
    assign is_exception[k] = commit_page_fault_inst[k] | commit_page_fault_load[k] | commit_page_fault_store[k] |
                             commit_illegal_inst[k] | (commit_inst_type[k] == ITYPE_ECALL);
    assign reclaim[k] = commit_valid[k] & commit_dest_en[k] & ~is_exception[k] & ~rob_interrupt;
    assign before_mask = reclaim & ~({C{1'b1}} << k);
    ttg_popcount #(.N(C)) u_rank (.bits(before_mask), .count(rank[k]));
  end

  ttg_popcount #(.N(C)) u_total (.bits(reclaim), .count(total));

endmodule

`default_nettype wire
