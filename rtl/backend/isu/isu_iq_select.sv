// Ref: back-end/include/IssueQueue.h  IssueQueue::schedule  (IQ_SLOT_PRIORITY: lowest slot first, port-centric)
`default_nettype none

// Port-by-port select: port p takes the lowest ready slot whose op class it supports and that no earlier port took.
// A slot taken by a port stays taken even when that port is not granted later (FU busy / issue blocked).
module isu_iq_select
  import isu_pkg::*;
#(
  parameter int SIZE      = 64,
  parameter int NP        = 4,
  parameter int PORT_BASE = 0                   // physical issue port of this queue's port 0
) (
  input  logic [SIZE-1:0] ready,
  input  op_set_t         entry_op [SIZE],      // one-hot op class of each slot
  output logic [SIZE-1:0] sel_onehot [NP],      // slot chosen by each port (all zero when none)
  output logic [NP-1:0]   sel_valid             // port found a slot
);

  logic [SIZE-1:0] taken [NP + 1];              // slots chosen by ports before p
  assign taken[0] = '0;

  for (genvar p = 0; p < NP; p++) begin : g_port
    localparam op_set_t CAP = port_cap(PORT_BASE + p);
    logic [SIZE-1:0] cap_match;
    logic [SIZE-1:0] candidate;
    for (genvar i = 0; i < SIZE; i++) begin : g_slot
      assign cap_match[i] = |(entry_op[i] & CAP);
    end
    assign candidate = ready & cap_match & ~taken[p];
    ttg_first_set #(.N(SIZE)) u_pick (.req(candidate), .onehot(sel_onehot[p]), .any(sel_valid[p]));
    assign taken[p + 1] = taken[p] | sel_onehot[p];
  end

  logic [SIZE-1:0] unused_taken_last;           // the final chain value has no consumer
  assign unused_taken_last = taken[NP];

endmodule

`default_nettype wire
