// Ref: front-end/BPU/BPU_pipe.h  State::tq (uBTB train queue)
`default_nettype none

// Train queue of the uBTB / L1: TQ_DEPTH entries, the head is consumed every cycle it is valid.  New events of the
// commit lanes are appended in program order behind the entries that remain after the pop; an event that finds the
// queue full is dropped (the queue is a hint table trainer, a lost event only costs a later retrain).
module bpu_ub_tq import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [NCOMMIT-1:0]  ev_valid,
  input  ub_ev_t              ev       [NCOMMIT],
  output logic                head_valid,
  output ub_ev_t              head,
  output logic [3:0]          occ               // entries held at the start of the cycle (compact ROB credits)
);

  localparam int CNT_W = $clog2(TQ_DEPTH + 1);

  ub_ev_t           tq_q [TQ_DEPTH];
  ub_ev_t           tq_d [TQ_DEPTH];
  logic [CNT_W-1:0] cnt_q;
  logic [CNT_W-1:0] cnt_d;

  assign head_valid = (cnt_q != '0);
  assign head       = tq_q[0];
  assign occ        = 4'(cnt_q);

  // Ref: ub_event: pop, then append behind the remaining entries
  always_comb begin
    int unsigned k;
    for (int i = 0; i < TQ_DEPTH - 1; i++) tq_d[i] = tq_q[i + 1];
    tq_d[TQ_DEPTH - 1] = '0;
    k = (cnt_q != '0) ? int'(cnt_q) - 1 : 0;
    for (int l = 0; l < NCOMMIT; l++) begin
      if (ev_valid[l] && k < TQ_DEPTH) begin
        tq_d[k] = ev[l];
        k = k + 1;
      end
    end
    cnt_d = CNT_W'(k);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) cnt_q <= '0;
    else        cnt_q <= cnt_d;
  end

  for (genvar i = 0; i < TQ_DEPTH; i++) begin : g_entry
    always_ff @(posedge clk) tq_q[i] <= tq_d[i];
  end

endmodule

`default_nettype wire
