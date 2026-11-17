// Ref: back-end/include/IssueQueue.h  IssueQueue::schedule  (IQ_SLOT_PRIORITY: lowest slot first, port-centric)
`default_nettype none

// Port-by-port select: port p takes the lowest ready slot whose op class it supports and that no earlier port took.
// A slot taken by a port stays taken even when that port is not granted later (FU busy / issue blocked).
module isu_iq_select
  import isu_pkg::*;
#(
  parameter int SIZE      = 64,
  parameter int NP        = 4,
  parameter int PORT_BASE = 0,                  // physical issue port of this queue's port 0
  // AGE_EN: the first port of each capability (no earlier port shares a capability bit with it) takes the oldest ready uop it can
  // serve (isu_oldest_pick), the other ports the lowest slot (the memory queue; docs/MEM_IQ.md in trace-model)
  parameter bit AGE_EN    = 1'b0
) (
  input  logic [SIZE-1:0] ready,
  input  op_set_t         entry_op [SIZE],      // one-hot op class of each slot
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: read only by a queue with AGE_EN
  input  logic [SIZE-1:0] older [SIZE],         // age matrix: older[i][j] = slot j is older than slot i
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [SIZE-1:0] sel_onehot [NP],      // slot chosen by each port (all zero when none)
  output logic [NP-1:0]   sel_valid             // port found a slot
);

  // Port p takes the lowest ready slot it can serve that no earlier port took. A slot taken by a port whose capabilities do not
  // overlap port p's could not be p's candidate anyway, so the chain only runs over ports with overlapping capabilities: the
  // load ports and the STA ports of a memory queue select independently (and the ports of a queue of one kind form one chain).
  logic [SIZE-1:0] taken [NP];                  // slots chosen by earlier ports that port p could also serve

  function automatic bit first_of_cap(input int base, input int p);
    bit f = 1'b1;
    for (int q = 0; q < p; q++) if ((port_cap(base + q) & port_cap(base + p)) != '0) f = 1'b0;
    return f;
  endfunction

  for (genvar p = 0; p < NP; p++) begin : g_port
    localparam op_set_t CAP = port_cap(PORT_BASE + p);
    logic [SIZE-1:0] cap_match;
    logic [SIZE-1:0] candidate;
    always_comb begin
      taken[p] = '0;
      for (int q = 0; q < p; q++)
        if ((port_cap(PORT_BASE + q) & CAP) != '0) taken[p] = taken[p] | sel_onehot[q];
    end
    for (genvar i = 0; i < SIZE; i++) begin : g_slot
      assign cap_match[i] = |(entry_op[i] & CAP);
    end
    assign candidate = ready & cap_match & ~taken[p];
    // first port of its capability: no earlier port could take any slot this port can
    localparam bit FIRST = first_of_cap(PORT_BASE, p);
    if (AGE_EN && FIRST) begin : g_age
      // the oldest candidate: a candidate with no older candidate
      for (genvar i = 0; i < SIZE; i++) begin : g_old
        assign sel_onehot[p][i] = candidate[i] && !(|(older[i] & candidate));
      end
      assign sel_valid[p] = |candidate;
    end else begin : g_slot_prio
      ttg_first_set #(.N(SIZE)) u_pick (.req(candidate), .onehot(sel_onehot[p]), .any(sel_valid[p]));
    end
  end

endmodule

`default_nettype wire
