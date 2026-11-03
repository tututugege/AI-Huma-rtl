// Ref: back-end/Rob.cpp  class Rob  (enq_ptr/deq_ptr/enq_flag/deq_flag, is_empty/is_full)
`default_nettype none

module rob_ptr
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         flush,          // Rob::comb_flush: back to the initial empty state
  input  logic                         recover,        // Rob::comb_branch active (mispred && !flush)
  input  logic [ROB_LINE_IDX_W-1:0]    redirect_line,  // line of dec_bcast.redirect_rob_idx
  input  logic                         enq_any,        // Rob::comb_fire: some slot is enqueued (tail advances one line)
  input  logic                         deq_advance,    // Rob::comb_commit: head line retired
  output logic [ROB_LINE_IDX_W-1:0]    enq_ptr,
  output logic [ROB_LINE_IDX_W-1:0]    deq_ptr,
  output logic                         enq_flag,
  output logic                         empty,
  output logic                         full,
  output logic [ROB_LINE_NUM-1:0]      enq_line_onehot,
  output logic [ROB_LINE_NUM-1:0]      deq_line_onehot
);

  logic [ROB_LINE_IDX_W-1:0] enq_ptr_q, enq_ptr_d, deq_ptr_q, deq_ptr_d;
  logic                      enq_flag_q, enq_flag_d, deq_flag_q, deq_flag_d;

  // after Rob::comb_branch: tail rolls back to the line after the redirecting branch
  logic [ROB_LINE_IDX_W-1:0] enq_ptr_rec;
  logic                      enq_flag_rec;
  // after Rob::comb_fire: advance on top of the rolled-back tail (C++ LOOP_INC(enq_ptr_1))
  logic [ROB_LINE_IDX_W-1:0] enq_ptr_inc;
  logic                      enq_flag_inc;

  // Ref: Rob::comb_branch (pointer part)
  always_comb begin
    enq_ptr_rec  = enq_ptr_q;
    enq_flag_rec = enq_flag_q;
    if (recover) begin
      enq_ptr_rec = rob_line_inc(redirect_line);
      if (enq_ptr_rec > enq_ptr_q) enq_flag_rec = !enq_flag_q;
    end
  end

  // Ref: Rob::comb_fire (pointer part)
  always_comb begin
    enq_ptr_inc  = enq_ptr_rec;
    enq_flag_inc = enq_flag_rec;
    if (enq_any) begin
      enq_ptr_inc = rob_line_inc(enq_ptr_rec);
      if (enq_ptr_inc == '0) enq_flag_inc = !enq_flag_rec;
    end
  end

  // Ref: Rob::comb_commit (deq part) and Rob::comb_flush (overrides everything)
  always_comb begin
    deq_ptr_d  = deq_ptr_q;
    deq_flag_d = deq_flag_q;
    if (deq_advance) begin
      deq_ptr_d = rob_line_inc(deq_ptr_q);
      if (deq_ptr_d == '0) deq_flag_d = !deq_flag_q;
    end
    enq_ptr_d  = enq_ptr_inc;
    enq_flag_d = enq_flag_inc;
    if (flush) begin
      enq_ptr_d  = '0;
      deq_ptr_d  = '0;
      enq_flag_d = 1'b0;
      deq_flag_d = 1'b0;
    end
  end

  // Ref: Rob::seq
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      enq_ptr_q  <= '0;
      deq_ptr_q  <= '0;
      enq_flag_q <= 1'b0;
      deq_flag_q <= 1'b0;
    end else begin
      enq_ptr_q  <= enq_ptr_d;
      deq_ptr_q  <= deq_ptr_d;
      enq_flag_q <= enq_flag_d;
      deq_flag_q <= deq_flag_d;
    end
  end

  // Ref: Rob::is_empty / is_full
  always_comb begin
    empty = (enq_ptr_q == deq_ptr_q) && (enq_flag_q == deq_flag_q);
    full  = (enq_ptr_q == deq_ptr_q) && (enq_flag_q != deq_flag_q);
    for (int l = 0; l < ROB_LINE_NUM; l++) begin
      enq_line_onehot[l] = (enq_ptr_q == ROB_LINE_IDX_W'(l));
      deq_line_onehot[l] = (deq_ptr_q == ROB_LINE_IDX_W'(l));
    end
  end

  assign enq_ptr  = enq_ptr_q;
  assign deq_ptr  = deq_ptr_q;
  assign enq_flag = enq_flag_q;

endmodule

`default_nettype wire
