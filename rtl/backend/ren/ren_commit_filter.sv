// Ref: back-end/Ren.cpp  class Ren  Ren::comb_fire (commit part)
`default_nettype none

// Which ROB commit slots retire a destination (update the arch RAT, release the old register), and how many of them
// took a register from the free list at rename (head_commit advance).
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
  input  logic [C-1:0]                 commit_elim,   // eliminated move: allocated no register
  input  logic                         rob_interrupt,
  output logic [C-1:0]                 reclaim,       // commit slot retires a dest and is not an exception/interrupt
  output logic [CW-1:0]                alloc_total    // reclaiming slots that took a register from the free list
);

  logic [C-1:0] is_exception;

  for (genvar k = 0; k < C; k++) begin : g_slot
    assign is_exception[k] = commit_page_fault_inst[k] | commit_page_fault_load[k] | commit_page_fault_store[k] |
                             commit_illegal_inst[k] | (commit_inst_type[k] == ITYPE_ECALL);
    assign reclaim[k] = commit_valid[k] & commit_dest_en[k] & ~is_exception[k] & ~rob_interrupt;
  end

  ttg_popcount #(.N(C)) u_alloc_total (.bits(reclaim & ~commit_elim), .count(alloc_total));

endmodule

`default_nettype wire
