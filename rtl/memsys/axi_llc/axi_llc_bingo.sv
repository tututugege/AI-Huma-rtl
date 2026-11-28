`default_nettype none
// Ref: MemSubSystem/include/BingoHw.h + axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp (EXP-058)
// Hardware-faithful LLC Bingo 4KB Spatial Prefetcher top:
//   * axi_llc_bingo_agt: FT (32 FIFO) + AGT (32 31b tree-PLRU) + 4-entry commit FIFO
//   * axi_llc_bingo_pht: PHT_L (256x4 1RW SRAM) + PHT_S (128x4 1RW SRAM) + dense filter
//   * Accuracy throttler (win=256, min=26 => 10.16%, 1/8 probe deg=2) + 1-cand/cycle emitter -> 16-entry bingo_q.
module axi_llc_bingo
  import axi_llc_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        pop_head,
  input  logic        pf_sent,
  input  logic        trig_v,
  input  logic        trig_pf,
  input  logic [25:0] trig_line,
  input  logic [11:0] trig_pch,
  input  logic        evict_v,
  input  logic [19:0] evict_reg,
  output logic        q_empty,
  output logic [25:0] q_head_line
);
  localparam int BQ_N      = BINGO_Q;
  localparam int B_DEG     = BINGO_DEG;
  localparam int B_THR_DEG = BINGO_THR_DEG;
  localparam int B_TWIN    = BINGO_TWIN;
  localparam int B_TMIN    = BINGO_TMIN;

  logic        pred_pend_v, pred_consume, cmt_empty, cmt_pop, pred_out_v;
  logic [19:0] pred_pend_reg, pred_out_reg;
  logic [17:0] pred_pend_key, cmt_head_key;
  logic [11:0] pred_pend_pch;
  logic [5:0]  pred_pend_off, cmt_head_off, pred_out_off;
  logic [63:0] cmt_head_mask, pred_out_mask;

  axi_llc_bingo_agt u_agt (
    .clk, .rst_n, .trig_v, .trig_line, .trig_pch, .evict_v, .evict_reg,
    .pred_consume, .cmt_pop,
    .pred_pend_v_q(pred_pend_v), .pred_pend_reg_q(pred_pend_reg), .pred_pend_key_q(pred_pend_key),
    .pred_pend_pch_q(pred_pend_pch), .pred_pend_off_q(pred_pend_off),
    .cmt_empty, .cmt_head_key, .cmt_head_off, .cmt_head_mask
  );

  axi_llc_bingo_pht u_pht (
    .clk, .rst_n,
    .pred_pend_v, .pred_pend_reg, .pred_pend_key, .pred_pend_pch, .pred_pend_off,
    .cmt_empty, .cmt_head_key, .cmt_head_off, .cmt_head_mask,
    .pred_consume, .cmt_pop,
    .pred_out_v, .pred_out_reg, .pred_out_off, .pred_out_mask
  );

  // Accuracy throttler
  logic [8:0] win_sent_q, win_sent_d, win_useful_q, win_useful_d, ns_tmp, nu_tmp;
  logic       throttled_q, throttled_d;
  logic [2:0] probe_cnt_q, probe_cnt_d;

  always_comb begin
    ns_tmp = win_sent_q + {8'd0, pf_sent};
    nu_tmp = win_useful_q + {8'd0, (trig_v && trig_pf)};
    if (ns_tmp >= 9'(B_TWIN)) begin
      throttled_d  = (nu_tmp < 9'(B_TMIN));
      win_sent_d   = 9'd0;
      win_useful_d = 9'd0;
    end else begin
      throttled_d  = throttled_q;
      win_sent_d   = ns_tmp;
      win_useful_d = nu_tmp;
    end
  end

  // 1-candidate/cycle burst emitter -> BQ_N-entry deduplicated FIFO (axi_llc_pfq)
  logic        emit_v_q, emit_v_d;
  logic [19:0] emit_reg_q, emit_reg_d;
  logic [5:0]  emit_off_q, emit_off_d;
  logic [63:0] emit_mask_q, emit_mask_d;
  logic [4:0]  emit_left_q, emit_left_d;

  logic [5:0]  rot_sh, emit_pick_d, emit_pick_idx;
  logic [63:0] emit_rot, emit_pick_oh;
  logic        emit_pick_any, push_cand;
  logic [25:0] cand_line;

  always_comb begin
    rot_sh   = emit_off_q + 6'd1;
    emit_rot = (rot_sh == 6'd0) ? emit_mask_q :
               ((emit_mask_q >> rot_sh) | (emit_mask_q << (7'd64 - {1'b0, rot_sh})));
  end
  ttg_first_set #(.N(64)) u_emit_fs (.req(emit_rot), .onehot(emit_pick_oh), .any(emit_pick_any));
  ttg_onehot_to_idx #(.N(64), .IDXW(6)) u_emit_idx (.onehot(emit_pick_oh), .idx(emit_pick_d));
  assign emit_pick_idx = rot_sh + emit_pick_d;

  always_comb begin
    emit_v_d    = emit_v_q;
    emit_reg_d  = emit_reg_q;
    emit_off_d  = emit_off_q;
    emit_mask_d = emit_mask_q;
    emit_left_d = emit_left_q;
    probe_cnt_d = probe_cnt_q;
    push_cand   = 1'b0;
    cand_line   = 26'd0;

    if (emit_v_q && (emit_left_q != 5'd0) && emit_pick_any) begin
      cand_line   = {emit_reg_q, emit_pick_idx};
      push_cand   = 1'b1;
      emit_mask_d = emit_mask_q & ~(64'd1 << emit_pick_idx);
      emit_left_d = emit_left_q - 5'd1;
      if ((emit_left_d == 5'd0) || (emit_mask_d == 64'd0)) emit_v_d = 1'b0;
    end
    if (pred_out_v) begin
      if (!throttled_q) begin
        emit_v_d    = 1'b1;
        emit_reg_d  = pred_out_reg;
        emit_off_d  = pred_out_off;
        emit_mask_d = pred_out_mask;
        emit_left_d = 5'(B_DEG);
      end else begin
        probe_cnt_d = probe_cnt_q + 3'd1;
        if (probe_cnt_q == 3'd0) begin
          emit_v_d    = 1'b1;
          emit_reg_d  = pred_out_reg;
          emit_off_d  = pred_out_off;
          emit_mask_d = pred_out_mask;
          emit_left_d = 5'(B_THR_DEG);
        end
      end
    end
  end

  // bingo_q: pop_head comes from axi_llc_bop (bingo_pop), which requires !q_empty, so the queue is never popped empty
  logic [25:0] cand_lines [1];
  assign cand_lines[0] = cand_line;
  axi_llc_pfq #(.N(BQ_N), .NCAND(1), .W(26), .RST_LINES(1'b0)) u_q (
    .clk, .rst_n, .pop(pop_head), .push_v(push_cand), .cand_line(cand_lines), .cand_sel(1'b0),
    .empty(q_empty), .head(q_head_line)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      win_sent_q   <= 9'd0;
      win_useful_q <= 9'd0;
      throttled_q  <= 1'b0;
      probe_cnt_q  <= 3'd0;
      emit_v_q     <= 1'b0;
    end else begin
      win_sent_q   <= win_sent_d;
      win_useful_q <= win_useful_d;
      throttled_q  <= throttled_d;
      probe_cnt_q  <= probe_cnt_d;
      emit_v_q     <= emit_v_d;
    end
  end

  always_ff @(posedge clk) begin
    emit_reg_q  <= emit_reg_d;
    emit_off_q  <= emit_off_d;
    emit_mask_q <= emit_mask_d;
    emit_left_q <= emit_left_d;
  end
endmodule
`default_nettype wire
