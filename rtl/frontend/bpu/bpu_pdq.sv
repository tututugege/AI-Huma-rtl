// Ref: front-end/BPU/BPU_pipe.h  State::pq (BPO_PDCKPT: checkpoint of every block in the PTAB)
`default_nettype none

// Checkpoint queue of the blocks between the end of S2 (PTAB write) and the predecode check.  One record per PTAB entry
// in PTAB order: pushed with the block, popped when the checker consumed the PTAB head (reported one cycle later),
// cleared by a refetch.  The head is the checkpoint of the block the checker has just looked at.
module bpu_pdq import bpu_stage_pkg::*; (
  input  logic  clk,
  input  logic  rst_n,
  input  logic  pop,
  input  logic  push,
  input  ck_t   push_ck,
  input  logic  clear,
  output logic  head_valid,
  output ck_t   head_ck
);

  localparam int PTR_W = $clog2(PQ_DEPTH);
  localparam int CNT_W = $clog2(PQ_DEPTH + 1);

  ck_t              mem_q [PQ_DEPTH];
  logic [PTR_W-1:0] rd_q, rd_d, wr_q, wr_d;
  logic [CNT_W-1:0] cnt_q, cnt_d;
  logic             do_pop;
  logic             do_push;

  // Ref: comb: pop (consumed head), push (block leaving S2), refetch clears
  always_comb begin
    head_valid = (cnt_q != '0);
    head_ck    = mem_q[rd_q];
    do_pop     = pop && head_valid;
    do_push    = push && (cnt_q - CNT_W'(do_pop) < CNT_W'(PQ_DEPTH));
    rd_d       = rd_q + PTR_W'(do_pop);
    wr_d       = wr_q + PTR_W'(do_push);
    cnt_d      = cnt_q - CNT_W'(do_pop) + CNT_W'(do_push);
    if (clear) begin
      rd_d  = '0;
      wr_d  = '0;
      cnt_d = '0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_q  <= '0;
      wr_q  <= '0;
      cnt_q <= '0;
    end else begin
      rd_q  <= rd_d;
      wr_q  <= wr_d;
      cnt_q <= cnt_d;
    end
  end

  always_ff @(posedge clk) begin
    if (do_push) mem_q[wr_q] <= push_ck;
  end

endmodule

`default_nettype wire
