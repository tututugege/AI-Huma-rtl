// Ref: back-end/Ren.cpp  class Ren  (free_list, free_head, free_head_commit, free_tail)
`default_nettype none

// Circular free list of physical registers with three pointers:
//   head        speculative allocation pointer (moves on rename fire, rolled back on mispredict/flush)
//   head_commit pointer to the oldest allocation not yet committed (flush rolls head back to it)
//   tail        where committed old_dest pregs are appended
// PRF_NUM is a power of two, so pointer arithmetic wraps naturally in PRF_IDX_WIDTH bits.
module ren_free_list
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [N-1:0]         alloc_fire,        // slots that take a preg this cycle
  input  logic [C-1:0]         reclaim,
  input  logic [CW-1:0]        reclaim_rank [C],
  input  logic [CW-1:0]        reclaim_total,
  input  preg_t                reclaim_preg [C],  // old_dest_preg of committing slots
  input  logic                 flush,
  input  logic                 mispred,
  input  preg_t                ckpt_head,         // alloc_checkpoint_head[dec_bcast.br_id]
  output preg_t                window [N],        // free_list[head + k]
  output preg_t                free_count,
  output preg_t                head
);

  localparam int AW = $clog2(N + 1);

  logic [PRF_NUM-1:0][PRF_IDX_WIDTH-1:0] list_q, list_d;
  preg_t head_q, head_d, head_commit_q, head_commit_d, tail_q, tail_d;
  logic [AW-1:0] alloc_count;
  preg_t write_ptr [C];

  assign head = head_q;

  // ---- read side: N consecutive entries starting at head (indexed reads, pointer wraps in PRF_IDX_WIDTH) ----
  assign free_count = tail_q - head_q;

  for (genvar k = 0; k < N; k++) begin : g_window
    assign window[k] = list_q[head_q + preg_t'(k)];
  end

  ttg_popcount #(.N(N)) u_alloc_count (.bits(alloc_fire), .count(alloc_count));

  // ---- write side: committed old_dest pregs append at tail + rank ----
  for (genvar k = 0; k < C; k++) begin : g_wptr
    assign write_ptr[k] = tail_q + preg_t'(reclaim_rank[k]);
  end

  for (genvar e = 0; e < PRF_NUM; e++) begin : g_entry
    logic [C-1:0] hit;
    preg_t        data [C];
    logic         hit_any;
    preg_t        hit_value;
    for (genvar k = 0; k < C; k++) begin : g_port
      assign hit[k]  = reclaim[k] & (write_ptr[k] == preg_t'(e));
      assign data[k] = reclaim_preg[k];
    end
    ren_last_write #(.N(C), .W(PRF_IDX_WIDTH)) u_wr (.hit(hit), .data(data), .any(hit_any), .value(hit_value));
    assign list_d[e] = hit_any ? hit_value : list_q[e];
  end

  // ---- pointers. Ref: Ren::comb_fire end ----
  // flush: head <- head_commit (after this cycle's commits); mispredict: head <- checkpoint. Reclaim always
  // appends at tail (C++ rolls tail back on mispredict, but only matters if a commit coincides with a mispredict,
  // which makes the C++ free-list sanity check fail: unreachable, not replicated).
  always_comb begin
    head_commit_d = head_commit_q + preg_t'(reclaim_total);
    tail_d        = tail_q + preg_t'(reclaim_total);
    if (flush)         head_d = head_commit_d;
    else if (mispred)  head_d = ckpt_head;
    else               head_d = head_q + preg_t'(alloc_count);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      list_q        <= free_list_init();
      head_q        <= '0;
      head_commit_q <= '0;
      tail_q        <= preg_t'(PRF_NUM - RAT_NUM);
    end else begin
      list_q        <= list_d;
      head_q        <= head_d;
      head_commit_q <= head_commit_d;
      tail_q        <= tail_d;
    end
  end

endmodule

`default_nettype wire
