// Ref: back-end/Ren.cpp  class Ren  (sparse K-entry FIFO checkpoint control, RenLog pointers, 8-wide forward walk FSM)
`default_nettype none

module ren_ckpt_ctl
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N        = DECODE_WIDTH,
  parameter int C        = COMMIT_WIDTH,
  parameter int NK       = REN_CKPT_NUM,
  parameter int INTERVAL = REN_CKPT_INTERVAL,
  parameter int KW       = (NK > 1) ? $clog2(NK) : 1
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [N-1:0]             inst_valid,
  input  logic [N-1:0]             fire,
  input  logic [N-1:0]             is_branch,
  input  logic [C-1:0]             commit_valid,
  input  logic                     flush,
  input  logic                     mispred,
  input  logic [ROB_IDX_WIDTH-1:0] dec_redirect_rob_idx,
  // RenLog / handshake interface
  output logic                     walk_active,
  output logic [N-1:0]             log_ok,           // lane fits in RenLog (and not walking)
  output logic [ROB_IDX_WIDTH-1:0] lane_rob_idx [N], // ROB index for each lane (valid prefix)
  output logic [ROB_IDX_WIDTH-1:0] rd_base,          // RenLog read base (walk_ptr when walking, else ren_rob_head)
  output logic [N-1:0]             walk_slot_en,     // slots active in current walk step
  // Single-write-port checkpoint data control (shared by INT and FP ren_ckpt)
  output logic                     ckpt_wr_en,
  output logic [KW-1:0]            ckpt_wr_slot,
  output logic [N-1:0]             ckpt_wr_lane_oh,
  output logic                     ckpt_rd_hit,      // 1: restore ckpt_rd_slot; 0: restore arch_rat/head_commit
  output logic [KW-1:0]            ckpt_rd_slot
);

  localparam int IW  = ROB_IDX_WIDTH;
  localparam int ICW = ROB_IDX_WIDTH + 1;
  localparam int CW  = $clog2(N + 1);
  localparam int KCW = $clog2(NK + 1);

  // ---- state ----
  logic [IW-1:0]  ren_rob_head_q, ren_rob_tail_q;
  logic [ICW-1:0] ren_log_used_q;
  logic [NK-1:0]  ckpt_valid_q;
  logic [IW-1:0]  ckpt_rob_idx_q [NK];
  logic [KW-1:0]  ckpt_head_q, ckpt_tail_q;
  logic [KCW-1:0] ckpt_count_q;
  logic           walk_active_q;
  logic [IW-1:0]  walk_ptr_q;
  logic [ICW-1:0] walk_rem_q;

  assign walk_active = walk_active_q;
  assign rd_base     = walk_active_q ? walk_ptr_q : ren_rob_head_q;

  // ---- RenLog free space & per-lane ROB indices ----
  logic [ICW-1:0] ren_log_free;
  assign ren_log_free = ICW'(ROB_NUM) - ren_log_used_q;

  for (genvar i = 0; i < N; i++) begin : g_lane_idx
    logic [CW-1:0] val_before;
    if (i == 0) begin : g_zero
      assign val_before = '0;
    end else begin : g_cnt
      logic [$clog2(i+1)-1:0] cnt_i;
      ttg_popcount #(.N(i)) u_pc (.bits(inst_valid[i-1:0]), .count(cnt_i));
      assign val_before = CW'(cnt_i);
    end
    assign lane_rob_idx[i] = ren_rob_tail_q + IW'(val_before);
    assign log_ok[i]       = ~walk_active_q & (ICW'(val_before) < ren_log_free);
  end

  logic [CW-1:0] commit_cnt;
  ttg_popcount #(.N(C)) u_cmt_pc  (.bits(commit_valid), .count(commit_cnt));

  // Precompute ren_log_used_d and ren_rob_tail_d for each firing prefix (independent of fire!)
  // so fire only drives a tiny (ICW + IW)-bit ren_last_write instead of popcount(fire) + 9-bit adder.
  logic [ICW-1:0] base_used, normal_used_d;
  logic [IW-1:0]  normal_tail_d;
  logic [ICW+IW-1:0] ptr_after [N], ptr_last;
  logic           any_fire_ctl;
  assign base_used = ren_log_used_q - ICW'(commit_cnt);
  for (genvar i = 0; i < N; i++) begin : g_ptr_after
    logic [CW-1:0] vb;
    if (i == 0) begin : g_vb0
      assign vb = '0;
    end else begin : g_vbn
      logic [$clog2(i+1)-1:0] c_i;
      ttg_popcount #(.N(i)) u_vb (.bits(inst_valid[i-1:0]), .count(c_i));
      assign vb = CW'(c_i);
    end
    assign ptr_after[i] = {base_used + ICW'(vb) + ICW'(1), lane_rob_idx[i] + IW'(1)};
  end
  ren_last_write #(.N(N), .W(ICW + IW)) u_ptr_next (
    .hit(fire), .data(ptr_after), .any(any_fire_ctl), .value(ptr_last)
  );
  assign {normal_used_d, normal_tail_d} = any_fire_ctl ? ptr_last : {base_used, ren_rob_tail_q};

  // ---- checkpoint allocation (at most 1 per cycle, registered capacity & anchor) ----
  logic           can_alloc;
  logic [KW-1:0]  last_slot;
  logic [IW-1:0]  anchor_idx;
  logic [N-1:0]   alloc_cand;
  logic           any_cand;
  logic [IW-1:0]  ckpt_wr_rob_idx;

  assign can_alloc  = (ckpt_count_q < KCW'(NK));
  assign last_slot  = ckpt_tail_q - KW'(1);
  assign anchor_idx = (ckpt_count_q != '0) ? ckpt_rob_idx_q[last_slot] : ren_rob_head_q;

  // Pre-select the first qualifying branch from inst_valid (independent of fire!) so ckpt_wr_lane_oh
  // and ren_rat's ckpt_wr_rat compute in parallel with ren_elim_sel / ren_alloc_sel / ren_handshake.
  // Because fire is an in-order prefix of inst_valid, the first qualifying branch fires iff |(ckpt_wr_lane_oh & fire).
  for (genvar i = 0; i < N; i++) begin : g_alloc_cand
    logic [IW-1:0] dist_i;
    assign dist_i        = lane_rob_idx[i] - anchor_idx;
    assign alloc_cand[i] = inst_valid[i] & is_branch[i] & (dist_i >= IW'(INTERVAL));
  end

  ttg_first_set #(.N(N)) u_pick_ckpt (.req(alloc_cand), .onehot(ckpt_wr_lane_oh), .any(any_cand));
  ttg_onehot_mux #(.N(N), .W(IW)) u_pick_ridx (.sel(ckpt_wr_lane_oh), .data(lane_rob_idx), .out(ckpt_wr_rob_idx));

  assign ckpt_wr_en   = ~flush & ~mispred & ~walk_active_q & can_alloc & any_cand & (|(ckpt_wr_lane_oh & fire));
  assign ckpt_wr_slot = ckpt_tail_q;

  // ---- commit-time checkpoint retirement ----
  logic [NK-1:0]  retire_k;
  logic [KCW-1:0] retire_cnt;
  logic [KW-1:0]  ckpt_head_after_ret;
  logic [KCW-1:0] ckpt_count_after_ret;
  logic [NK-1:0]  retire_slot_mask;

  for (genvar k = 0; k < NK; k++) begin : g_ret_k
    logic [KW-1:0] s;
    logic [IW-1:0] age_k;
    assign s         = ckpt_head_q + KW'(k);
    assign age_k     = ckpt_rob_idx_q[s] - ren_rob_head_q;
    assign retire_k[k] = (KCW'(k) < ckpt_count_q) & ckpt_valid_q[s] & ({1'b0, age_k} < ICW'(commit_cnt));
  end
  ttg_popcount #(.N(NK)) u_ret_pc (.bits(retire_k), .count(retire_cnt));
  assign ckpt_head_after_ret  = ckpt_head_q + KW'(retire_cnt);
  assign ckpt_count_after_ret = ckpt_count_q - retire_cnt;

  always_comb begin
    retire_slot_mask = '0;
    for (int k = 0; k < NK; k++) begin
      if (retire_k[k]) retire_slot_mask[ckpt_head_q + KW'(k)] = 1'b1;
    end
  end

  // ---- mispredict lookup: youngest checkpoint with age <= br_age ----
  logic [IW-1:0]  br_age;
  logic [NK-1:0]  usable_k;
  logic [KW-1:0]  best_k;
  logic [IW-1:0]  best_rob_idx, best_age;
  logic           mis_walk_active;
  logic [IW-1:0]  mis_walk_ptr;
  logic [ICW-1:0] mis_walk_rem;
  logic [KCW-1:0] mis_ckpt_count;
  logic [KW-1:0]  mis_ckpt_tail;
  logic [NK-1:0]  mis_ckpt_valid;

  assign br_age = dec_redirect_rob_idx - ren_rob_head_q;

  for (genvar k = 0; k < NK; k++) begin : g_mis_k
    logic [KW-1:0] s;
    logic [IW-1:0] age_k;
    assign s          = ckpt_head_q + KW'(k);
    assign age_k      = ckpt_rob_idx_q[s] - ren_rob_head_q;
    assign usable_k[k] = (KCW'(k) < ckpt_count_q) & ckpt_valid_q[s] & (age_k <= br_age);
  end

  always_comb begin
    ckpt_rd_hit = 1'b0;
    best_k      = '0;
    for (int k = 0; k < NK; k++) begin
      if (usable_k[k]) begin
        ckpt_rd_hit = 1'b1;
        best_k      = KW'(k);
      end
    end
    ckpt_rd_slot = ckpt_head_q + best_k;
    best_rob_idx = ckpt_rob_idx_q[ckpt_rd_slot];
    best_age     = best_rob_idx - ren_rob_head_q;

    mis_ckpt_valid = '0;
    if (ckpt_rd_hit) begin
      mis_walk_active = (best_age != br_age);
      mis_walk_ptr    = best_rob_idx + IW'(1);
      mis_walk_rem    = {1'b0, (br_age - best_age)};
      mis_ckpt_count  = KCW'(best_k) + KCW'(1);
      mis_ckpt_tail   = ckpt_head_q + KW'(mis_ckpt_count);
      for (int k = 0; k < NK; k++) begin
        if (KCW'(k) <= KCW'(best_k)) mis_ckpt_valid[ckpt_head_q + KW'(k)] = 1'b1;
      end
    end else begin
      mis_walk_active = 1'b1;
      mis_walk_ptr    = ren_rob_head_q;
      mis_walk_rem    = {1'b0, br_age} + ICW'(1);
      mis_ckpt_count  = '0;
      mis_ckpt_tail   = '0;
    end
  end

  // ---- walk step ----
  logic [CW-1:0] walk_step;
  assign walk_step = (walk_rem_q > ICW'(N)) ? CW'(N) : CW'(walk_rem_q);
  for (genvar k = 0; k < N; k++) begin : g_walk_en
    assign walk_slot_en[k] = walk_active_q & (CW'(k) < walk_step);
  end

  // ---- next state: flush > mispred > walk > normal ----
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      ren_rob_head_q <= '0;
      ren_rob_tail_q <= '0;
      ren_log_used_q <= '0;
      ckpt_valid_q   <= '0;
      ckpt_head_q    <= '0;
      ckpt_tail_q    <= '0;
      ckpt_count_q   <= '0;
      walk_active_q  <= 1'b0;
      walk_ptr_q     <= '0;
      walk_rem_q     <= '0;
      for (int s = 0; s < NK; s++) ckpt_rob_idx_q[s] <= '0;
    end else if (mispred) begin
      // Commit is 0 during mispredict, so ren_rob_head_q does not advance
      ren_rob_tail_q <= dec_redirect_rob_idx + IW'(1);
      ren_log_used_q <= {1'b0, br_age} + ICW'(1);
      ckpt_valid_q   <= mis_ckpt_valid;
      ckpt_head_q    <= ckpt_rd_hit ? ckpt_head_q : '0;
      ckpt_tail_q    <= mis_ckpt_tail;
      ckpt_count_q   <= mis_ckpt_count;
      walk_active_q  <= mis_walk_active;
      walk_ptr_q     <= mis_walk_ptr;
      walk_rem_q     <= mis_walk_rem;
    end else if (walk_active_q) begin
      // Commit is stalled during walk in 1R1W mode (commit_cnt == 0), still handle generically
      ren_rob_head_q <= ren_rob_head_q + IW'(commit_cnt);
      ren_log_used_q <= ren_log_used_q - ICW'(commit_cnt);
      ckpt_head_q    <= ckpt_head_after_ret;
      ckpt_count_q   <= ckpt_count_after_ret;
      ckpt_valid_q   <= ckpt_valid_q & ~retire_slot_mask;
      walk_ptr_q     <= walk_ptr_q + IW'(walk_step);
      walk_rem_q     <= walk_rem_q - ICW'(walk_step);
      walk_active_q  <= (walk_rem_q > ICW'(walk_step));
    end else begin
      ren_rob_head_q <= ren_rob_head_q + IW'(commit_cnt);
      ren_rob_tail_q <= normal_tail_d;
      ren_log_used_q <= normal_used_d;
      ckpt_head_q    <= ckpt_head_after_ret;
      ckpt_tail_q    <= ckpt_tail_q + KW'(ckpt_wr_en);
      ckpt_count_q   <= ckpt_count_after_ret + KCW'(ckpt_wr_en);
      ckpt_valid_q   <= (ckpt_valid_q & ~retire_slot_mask) | (ckpt_wr_en ? (NK'(1) << ckpt_wr_slot) : '0);
      if (ckpt_wr_en) ckpt_rob_idx_q[ckpt_wr_slot] <= ckpt_wr_rob_idx;
    end
  end

endmodule

`default_nettype wire
