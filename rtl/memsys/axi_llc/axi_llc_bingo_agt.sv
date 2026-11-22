`default_nettype none
// Ref: MemSubSystem/include/BingoHw.h (EXP-058)
// Filter Table (32-entry FIFO) + Accumulation Table (32-entry 31b tree-PLRU) + 4-entry commit FIFO
// + 1-entry pending prediction latch for axi_llc_bingo.
module axi_llc_bingo_agt
  import axi_llc_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        trig_v,
  input  logic [25:0] trig_line,
  input  logic [11:0] trig_pch,
  input  logic        evict_v,
  input  logic [19:0] evict_reg,
  input  logic        pred_consume,
  input  logic        cmt_pop,
  output logic        pred_pend_v_q,
  output logic [19:0] pred_pend_reg_q,
  output logic [17:0] pred_pend_key_q,
  output logic [11:0] pred_pend_pch_q,
  output logic [5:0]  pred_pend_off_q,
  output logic        cmt_empty,
  output logic [17:0] cmt_head_key,
  output logic [5:0]  cmt_head_off,
  output logic [63:0] cmt_head_mask
);
  localparam int FT_N   = BINGO_FT_N;
  localparam int AGT_N  = BINGO_AGT_N;
  localparam int CMTQ_N = BINGO_CMTQ_N;

  function automatic logic [30:0] plru32_update(input logic [30:0] p, input logic [4:0] s);
    logic [30:0] n;
    int node;
    n = p;
    node = 0;
    for (int lvl = 4; lvl >= 0; lvl--) begin
      if (s[lvl]) begin
        n[node] = 1'b0;
        node = 2 * node + 2;
      end else begin
        n[node] = 1'b1;
        node = 2 * node + 1;
      end
    end
    return n;
  endfunction

  function automatic logic [4:0] plru32_victim(input logic [30:0] p);
    logic [4:0] s;
    int node;
    s = 5'd0;
    node = 0;
    for (int lvl = 4; lvl >= 0; lvl--) begin
      s[lvl] = p[node];
      node = p[node] ? (2 * node + 2) : (2 * node + 1);
    end
    return s;
  endfunction

  logic [FT_N-1:0]  ft_v_q, ft_v_d;
  logic [19:0]      ft_reg_q [FT_N], ft_reg_d [FT_N];
  logic [17:0]      ft_key_q [FT_N], ft_key_d [FT_N];
  logic [5:0]       ft_off_q [FT_N], ft_off_d [FT_N];
  logic [4:0]       ft_ptr_q, ft_ptr_d;

  logic [AGT_N-1:0] agt_v_q, agt_v_ev, agt_v_d;
  logic [19:0]      agt_reg_q [AGT_N], agt_reg_d [AGT_N];
  logic [17:0]      agt_key_q [AGT_N], agt_key_d [AGT_N];
  logic [5:0]       agt_off_q [AGT_N], agt_off_d [AGT_N];
  logic [63:0]      agt_mask_q [AGT_N], agt_mask_d [AGT_N];
  logic [30:0]      agt_plru_q, agt_plru_d;

  logic             pred_pend_v_d;
  logic [19:0]      pred_pend_reg_d;
  logic [17:0]      pred_pend_key_d;
  logic [11:0]      pred_pend_pch_d;
  logic [5:0]       pred_pend_off_d;

  logic [17:0]      cmt_q_key_q [CMTQ_N], cmt_p_key [CMTQ_N], cmt_q_key_d [CMTQ_N];
  logic [5:0]       cmt_q_off_q [CMTQ_N], cmt_p_off [CMTQ_N], cmt_q_off_d [CMTQ_N];
  logic [63:0]      cmt_q_mask_q [CMTQ_N], cmt_p_mask [CMTQ_N], cmt_q_mask_d [CMTQ_N];
  logic [2:0]       cmt_cnt_q, cmt_p_cnt, cmt_cnt_d;

  assign cmt_empty     = (cmt_cnt_q == 3'd0);
  assign cmt_head_key  = cmt_q_key_q[0];
  assign cmt_head_off  = cmt_q_off_q[0];
  assign cmt_head_mask = cmt_q_mask_q[0];

  // Stage A: LLC eviction check on AGT
  logic        ev_cmt_v;
  logic [17:0] ev_cmt_key;
  logic [5:0]  ev_cmt_off;
  logic [63:0] ev_cmt_mask;
  logic [AGT_N-1:0] ev_match, ev_oh;
  logic             ev_any;
  logic [4:0]       ev_idx;

  always_comb begin
    for (int i = 0; i < AGT_N; i++) ev_match[i] = evict_v && agt_v_q[i] && (agt_reg_q[i] == evict_reg);
  end
  ttg_first_set #(.N(AGT_N)) u_ev_fs (.req(ev_match), .onehot(ev_oh), .any(ev_any));
  ttg_onehot_to_idx #(.N(AGT_N), .IDXW(5)) u_ev_idx (.onehot(ev_oh), .idx(ev_idx));

  always_comb begin
    agt_v_ev    = ev_any ? (agt_v_q & ~ev_oh) : agt_v_q;
    ev_cmt_key  = agt_key_q[ev_idx];
    ev_cmt_off  = agt_off_q[ev_idx];
    ev_cmt_mask = agt_mask_q[ev_idx];
    ev_cmt_v    = ev_any && ((ev_cmt_mask & ~(64'd1 << ev_cmt_off)) != 64'd0);
  end

  // Stage B: trigger lookup in AGT (post-evict) and FT + victim selection
  logic [19:0] treg;
  logic [5:0]  toff;
  logic [17:0] tkey;
  logic [AGT_N-1:0] a_match, a_oh, a_inv_oh;
  logic [FT_N-1:0]  f_match, f_oh;
  logic             a_hit, f_hit, a_inv_any;
  logic [4:0]       a_idx, f_idx, a_inv_idx, a_vict;

  assign treg = trig_line[25:6];
  assign toff = trig_line[5:0];
  assign tkey = {trig_pch, toff};

  always_comb begin
    for (int i = 0; i < AGT_N; i++) a_match[i] = trig_v && agt_v_ev[i] && (agt_reg_q[i] == treg);
    for (int i = 0; i < FT_N;  i++) f_match[i] = trig_v && ft_v_q[i]   && (ft_reg_q[i]  == treg);
  end
  ttg_first_set #(.N(AGT_N)) u_a_fs (.req(a_match), .onehot(a_oh), .any(a_hit));
  ttg_onehot_to_idx #(.N(AGT_N), .IDXW(5)) u_a_idx (.onehot(a_oh), .idx(a_idx));
  ttg_first_set #(.N(FT_N))  u_f_fs (.req(f_match), .onehot(f_oh), .any(f_hit));
  ttg_onehot_to_idx #(.N(FT_N),  .IDXW(5)) u_f_idx (.onehot(f_oh), .idx(f_idx));
  ttg_first_set #(.N(AGT_N)) u_ainv_fs (.req(~agt_v_ev), .onehot(a_inv_oh), .any(a_inv_any));
  ttg_onehot_to_idx #(.N(AGT_N), .IDXW(5)) u_ainv_idx (.onehot(a_inv_oh), .idx(a_inv_idx));
  assign a_vict = a_inv_any ? a_inv_idx : plru32_victim(agt_plru_q);

  // Stage C: FT / AGT / pred_pend next state
  logic        pr_cmt_v, do_promote, do_trigger;
  logic [17:0] pr_cmt_key;
  logic [5:0]  pr_cmt_off;
  logic [63:0] pr_cmt_mask;

  always_comb begin
    do_promote = trig_v && !a_hit && f_hit && (ft_off_q[f_idx] != toff);
    do_trigger = trig_v && !a_hit && !f_hit;

    ft_v_d     = ft_v_q;
    ft_ptr_d   = ft_ptr_q;
    agt_v_d    = agt_v_ev;
    agt_plru_d = agt_plru_q;
    for (int i = 0; i < FT_N; i++) begin
      ft_reg_d[i] = ft_reg_q[i];
      ft_key_d[i] = ft_key_q[i];
      ft_off_d[i] = ft_off_q[i];
    end
    for (int i = 0; i < AGT_N; i++) begin
      agt_reg_d[i]  = agt_reg_q[i];
      agt_key_d[i]  = agt_key_q[i];
      agt_off_d[i]  = agt_off_q[i];
      agt_mask_d[i] = agt_mask_q[i];
    end

    pr_cmt_key  = agt_key_q[a_vict];
    pr_cmt_off  = agt_off_q[a_vict];
    pr_cmt_mask = agt_mask_q[a_vict];
    pr_cmt_v    = do_promote && agt_v_ev[a_vict] && ((pr_cmt_mask & ~(64'd1 << pr_cmt_off)) != 64'd0);

    pred_pend_v_d   = pred_consume ? 1'b0 : pred_pend_v_q;
    pred_pend_reg_d = pred_pend_reg_q;
    pred_pend_key_d = pred_pend_key_q;
    pred_pend_pch_d = pred_pend_pch_q;
    pred_pend_off_d = pred_pend_off_q;

    if (a_hit) begin
      agt_mask_d[a_idx] = agt_mask_q[a_idx] | (64'd1 << toff);
      agt_plru_d        = plru32_update(agt_plru_q, a_idx);
    end else if (do_promote) begin
      agt_v_d[a_vict]    = 1'b1;
      agt_reg_d[a_vict]  = treg;
      agt_key_d[a_vict]  = ft_key_q[f_idx];
      agt_off_d[a_vict]  = ft_off_q[f_idx];
      agt_mask_d[a_vict] = (64'd1 << ft_off_q[f_idx]) | (64'd1 << toff);
      agt_plru_d         = plru32_update(agt_plru_q, a_vict);
      ft_v_d[f_idx]      = 1'b0;
    end else if (do_trigger) begin
      ft_v_d[ft_ptr_q]   = 1'b1;
      ft_reg_d[ft_ptr_q] = treg;
      ft_key_d[ft_ptr_q] = tkey;
      ft_off_d[ft_ptr_q] = toff;
      ft_ptr_d           = ft_ptr_q + 5'd1;
      pred_pend_v_d      = 1'b1;
      pred_pend_reg_d    = treg;
      pred_pend_key_d    = tkey;
      pred_pend_pch_d    = trig_pch;
      pred_pend_off_d    = toff;
    end
  end

  // Stage D: commit FIFO pop + push (evict then promote)
  always_comb begin
    for (int i = 0; i < CMTQ_N; i++) begin
      cmt_p_key[i]  = (cmt_pop && (i + 1 < CMTQ_N)) ? cmt_q_key_q[i + 1]  : cmt_q_key_q[i];
      cmt_p_off[i]  = (cmt_pop && (i + 1 < CMTQ_N)) ? cmt_q_off_q[i + 1]  : cmt_q_off_q[i];
      cmt_p_mask[i] = (cmt_pop && (i + 1 < CMTQ_N)) ? cmt_q_mask_q[i + 1] : cmt_q_mask_q[i];
    end
    cmt_p_cnt = (cmt_pop && (cmt_cnt_q != 3'd0)) ? (cmt_cnt_q - 3'd1) : cmt_cnt_q;
    for (int i = 0; i < CMTQ_N; i++) begin
      cmt_q_key_d[i]  = cmt_p_key[i];
      cmt_q_off_d[i]  = cmt_p_off[i];
      cmt_q_mask_d[i] = cmt_p_mask[i];
    end
    cmt_cnt_d = cmt_p_cnt;
    if (ev_cmt_v && (cmt_cnt_d < 3'(CMTQ_N))) begin
      cmt_q_key_d[cmt_cnt_d[1:0]]  = ev_cmt_key;
      cmt_q_off_d[cmt_cnt_d[1:0]]  = ev_cmt_off;
      cmt_q_mask_d[cmt_cnt_d[1:0]] = ev_cmt_mask;
      cmt_cnt_d = cmt_cnt_d + 3'd1;
    end
    if (pr_cmt_v && (cmt_cnt_d < 3'(CMTQ_N))) begin
      cmt_q_key_d[cmt_cnt_d[1:0]]  = pr_cmt_key;
      cmt_q_off_d[cmt_cnt_d[1:0]]  = pr_cmt_off;
      cmt_q_mask_d[cmt_cnt_d[1:0]] = pr_cmt_mask;
      cmt_cnt_d = cmt_cnt_d + 3'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ft_v_q        <= '0;
      ft_ptr_q      <= 5'd0;
      agt_v_q       <= '0;
      agt_plru_q    <= 31'd0;
      pred_pend_v_q <= 1'b0;
      cmt_cnt_q     <= 3'd0;
    end else begin
      ft_v_q        <= ft_v_d;
      ft_ptr_q      <= ft_ptr_d;
      agt_v_q       <= agt_v_d;
      agt_plru_q    <= agt_plru_d;
      pred_pend_v_q <= pred_pend_v_d;
      cmt_cnt_q     <= cmt_cnt_d;
    end
  end

  always_ff @(posedge clk) begin
    pred_pend_reg_q <= pred_pend_reg_d;
    pred_pend_key_q <= pred_pend_key_d;
    pred_pend_pch_q <= pred_pend_pch_d;
    pred_pend_off_q <= pred_pend_off_d;
    for (int i = 0; i < FT_N; i++) begin
      ft_reg_q[i] <= ft_reg_d[i];
      ft_key_q[i] <= ft_key_d[i];
      ft_off_q[i] <= ft_off_d[i];
    end
    for (int i = 0; i < AGT_N; i++) begin
      agt_reg_q[i]  <= agt_reg_d[i];
      agt_key_q[i]  <= agt_key_d[i];
      agt_off_q[i]  <= agt_off_d[i];
      agt_mask_q[i] <= agt_mask_d[i];
    end
    for (int i = 0; i < CMTQ_N; i++) begin
      cmt_q_key_q[i]  <= cmt_q_key_d[i];
      cmt_q_off_q[i]  <= cmt_q_off_d[i];
      cmt_q_mask_q[i] <= cmt_q_mask_d[i];
    end
  end
endmodule
`default_nettype wire
