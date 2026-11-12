// Ref: back-end/Ren.cpp  class Ren  (fp_free_list, fp_free_head, fp_free_head_commit, fp_free_tail; F/D)
`default_nettype none

// Circular free list of FP physical registers: same three pointers as ren_free_list, but the ring has FPRF_NUM slots,
// which is not a power of two, so pointer arithmetic wraps explicitly (fp_ptr_add).
module ren_fp_free_list
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [N-1:0]         alloc_fire,        // slots that take an FP register this cycle
  input  logic [C-1:0]         reclaim,
  input  logic [CW-1:0]        reclaim_rank [C],
  input  logic [CW-1:0]        reclaim_total,     // = head_commit advance (no move elimination in the FP domain)
  input  preg_t                reclaim_preg [C],  // old_dest_preg of committing slots
  input  logic                 flush,
  input  logic                 mispred,
  input  fp_ptr_t              ckpt_head,         // fp_alloc_checkpoint_head[dec_bcast.br_id]
  output preg_t                window [N],        // free_list[head + k]
  output fp_ptr_t              free_count,
  output fp_ptr_t              head
);

  localparam int AW = $clog2(N + 1);

  logic [FPN-1:0][PRF_IDX_WIDTH-1:0] list_q;
  fp_ptr_t head_q, head_d, head_commit_q, head_commit_d, tail_q, tail_d;
  fp_ptr_t write_ptr [C];
  logic [AW-1:0] alloc_count;

  assign head = head_q;
  assign free_count = (tail_q >= head_q) ? (tail_q - head_q) : fp_ptr_t'(tail_q + fp_ptr_t'(FPN) - head_q);

  for (genvar k = 0; k < N; k++) begin : g_window
    assign window[k] = list_q[fp_ptr_add(head_q, fp_ptr_t'(k))];
  end

  ttg_popcount #(.N(N)) u_alloc_count (.bits(alloc_fire), .count(alloc_count));

  // ---- committed old_dest pregs append at tail + rank; a later commit slot never collides with an earlier one ----
  for (genvar k = 0; k < C; k++) begin : g_wptr
    assign write_ptr[k] = fp_ptr_add(tail_q, fp_ptr_t'(reclaim_rank[k]));
  end

  for (genvar e = 0; e < FPN; e++) begin : g_entry
    logic [C-1:0] hit;
    preg_t        data [C];
    logic         hit_any;
    preg_t        hit_value;
    for (genvar k = 0; k < C; k++) begin : g_port
      assign hit[k]  = reclaim[k] & (write_ptr[k] == fp_ptr_t'(e));
      assign data[k] = reclaim_preg[k];
    end
    ren_last_write #(.N(C), .W(PRF_IDX_WIDTH)) u_wr (.hit(hit), .data(data), .any(hit_any), .value(hit_value));
    always_ff @(posedge clk) begin
      if (!rst_n)       list_q[e] <= fp_free_list_init()[e];
      else if (hit_any) list_q[e] <= hit_value;
    end
  end

  // flush: head <- head_commit (after this cycle's commits); mispredict: head <- checkpoint; reclaim always appends
  always_comb begin
    head_commit_d = fp_ptr_add(head_commit_q, fp_ptr_t'(reclaim_total));
    tail_d        = fp_ptr_add(tail_q, fp_ptr_t'(reclaim_total));
    if (flush)         head_d = head_commit_d;
    else if (mispred)  head_d = ckpt_head;
    else               head_d = fp_ptr_add(head_q, fp_ptr_t'(alloc_count));
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q        <= '0;
      head_commit_q <= '0;
      tail_q        <= fp_ptr_t'(FPN - FP_ARF_NUM);
    end else begin
      head_q        <= head_d;
      head_commit_q <= head_commit_d;
      tail_q        <= tail_d;
    end
  end

endmodule

`default_nettype wire
