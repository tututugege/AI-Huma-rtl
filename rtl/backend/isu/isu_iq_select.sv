// Ref: back-end/include/IssueQueue.h  IssueQueue::schedule  (IQ_SLOT_PRIORITY: lowest slot first, port-centric)
`default_nettype none

// Port-by-port select: port p takes the lowest ready slot whose op class it supports and that no earlier port took.
// A slot taken by a port stays taken even when that port is not granted later (FU busy / issue blocked).
module isu_iq_select
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SIZE      = 64,
  parameter int NP        = 4,
  parameter int QID       = 0,                  // issue queue number (its ports: isu_pkg iq_port)
  // AGE_EN: the first port of each capability (no earlier port shares a capability bit with it) takes the oldest ready uop it can
  // serve (isu_oldest_pick), the other ports the lowest slot (the memory queue; docs/MEM_IQ.md in trace-model)
  parameter bit AGE_EN    = 1'b0
) (
  input  logic [SIZE-1:0] ready,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: read only by a queue with AGE_EN
  input  logic [SIZE-1:0] older [SIZE],         // age matrix: older[i][j] = slot j is older than slot i
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [SIZE-1:0] port_ok [NP],         // slots port p may take this cycle (cap_match & completion cycle free)
  output logic [SIZE-1:0] sel_onehot [NP],      // slot chosen by each port (all zero when none)
  output logic [NP-1:0]   sel_valid             // port found a slot
);

  function automatic bit first_of_cap(input int qid, input int p);
    bit f = 1'b1;
    for (int q = 0; q < p; q++) if ((port_cap(iq_port(qid, q)) & port_cap(iq_port(qid, p))) != '0) f = 1'b0;
    return f;
  endfunction

  if (QID == IQ_MEM && AGE_EN && NP == LSU_LDU_COUNT + LSU_STA_COUNT) begin : g_mem_par
    localparam int NLD  = LSU_LDU_COUNT;
    localparam int NSTA = LSU_STA_COUNT;

    // ---- Load group: port 0 = oldest, ports 1..NLD-1 = lowest 1st..(NLD-1)-th remaining in parallel ----
    logic [SIZE-1:0] ld_cand, ld_rem;
    assign ld_cand = ready & port_ok[0];
    for (genvar i = 0; i < SIZE; i++) begin : g_ld0
      assign sel_onehot[0][i] = ld_cand[i] && !(|(older[i] & ld_cand));
    end
    assign sel_valid[0] = |ld_cand;
    assign ld_rem       = ld_cand & ~sel_onehot[0];

    if (NLD > 1) begin : g_ld_rest
      localparam int K = NLD - 1;
      logic [SIZE-1:0] ld_oh [K];
      logic [K-1:0]    ld_v;
      ttg_pick_k #(.N(SIZE), .K(K)) u_ld_rest (.req(ld_rem), .pick_oh(ld_oh), .valid(ld_v));
      for (genvar k = 0; k < K; k++) begin : g_k
        assign sel_onehot[1 + k] = ld_oh[k];
        assign sel_valid[1 + k]  = ld_v[k];
      end
    end

    // ---- STA group: port NLD = oldest, ports NLD+1..NP-1 = lowest 1st..(NSTA-1)-th remaining in parallel ----
    logic [SIZE-1:0] sta_cand, sta_rem;
    assign sta_cand = ready & port_ok[NLD];
    for (genvar i = 0; i < SIZE; i++) begin : g_sta0
      assign sel_onehot[NLD][i] = sta_cand[i] && !(|(older[i] & sta_cand));
    end
    assign sel_valid[NLD] = |sta_cand;
    assign sta_rem        = sta_cand & ~sel_onehot[NLD];

    if (NSTA > 1) begin : g_sta_rest
      localparam int K = NSTA - 1;
      logic [SIZE-1:0] sta_oh [K];
      logic [K-1:0]    sta_v;
      ttg_pick_k #(.N(SIZE), .K(K)) u_sta_rest (.req(sta_rem), .pick_oh(sta_oh), .valid(sta_v));
      for (genvar k = 0; k < K; k++) begin : g_k
        assign sel_onehot[NLD + 1 + k] = sta_oh[k];
        assign sel_valid[NLD + 1 + k]  = sta_v[k];
      end
    end

    /* verilator lint_off UNUSEDSIGNAL */   // waiver: port_ok[1..NLD-1] == port_ok[0] and port_ok[NLD+1..NP-1] == port_ok[NLD]
    logic unused_pok;
    always_comb begin
      unused_pok = 1'b0;
      for (int p = 0; p < NP; p++) unused_pok ^= ^port_ok[p];
    end
    /* verilator lint_on UNUSEDSIGNAL */
  end else begin : g_serial
    // Port p takes the lowest ready slot it can serve that no earlier port took. A slot taken by a port whose capabilities do not
    // overlap port p's could not be p's candidate anyway, so the chain only runs over ports with overlapping capabilities.
    logic [SIZE-1:0] taken [NP];                  // slots chosen by earlier ports that port p could also serve

    for (genvar p = 0; p < NP; p++) begin : g_port
      localparam op_set_t CAP = port_cap(iq_port(QID, p));
      logic [SIZE-1:0] candidate;
      always_comb begin
        taken[p] = '0;
        for (int q = 0; q < p; q++)
          if ((port_cap(iq_port(QID, q)) & CAP) != '0) taken[p] = taken[p] | sel_onehot[q];
      end
      assign candidate = ready & port_ok[p] & ~taken[p];
      // first port of its capability: no earlier port could take any slot this port can
      localparam bit FIRST = first_of_cap(QID, p);
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
  end

endmodule

`default_nettype wire
