// Ref: back-end/include/IssueQueue.h  IssueQueue::schedule (OLDEST_ON_FIRST_PORT: the oldest ready uop by ROB order, ties: lowest slot)
`default_nettype none

// Age matrix of an issue queue: older[i][j] = slot j holds an older uop than slot i. Uops enter in program order, so a new
// slot is younger than every valid slot; slots written in the same cycle take the free slots lowest first in lane order, so
// among them the lower slot is the older one. Only the rows of the slots written this cycle and the bits that name a written
// slot change; the rows of invalid slots are never read (the pick masks them with the candidates).
module isu_age_matrix #(
  parameter int SIZE = 64
) (
  input  logic            clk,
  input  logic [SIZE-1:0] write,        // slots written this cycle
  input  logic [SIZE-1:0] slot_valid,   // registered valid bits (before this cycle's issue / enqueue)
  output logic [SIZE-1:0] older [SIZE]  // older[i][j]: j is older than i
);

  logic [SIZE-1:0] m_q [SIZE];

  for (genvar i = 0; i < SIZE; i++) begin : g_row
    logic [SIZE-1:0] m_d;
    for (genvar j = 0; j < SIZE; j++) begin : g_col
      if (i == j) begin : g_diag
        assign m_d[j] = 1'b0;
      end else begin : g_off
        assign m_d[j] = write[i] ? ((slot_valid[j] && !write[j]) || (write[j] && (j < i)))   // a new slot: valid slots and lower new slots are older
                                 : (write[j] ? 1'b0 : m_q[i][j]);                              // a new j is younger than the rest
      end
    end
    always_ff @(posedge clk) m_q[i] <= m_d;
    assign older[i] = m_q[i];
  end

endmodule

`default_nettype wire
