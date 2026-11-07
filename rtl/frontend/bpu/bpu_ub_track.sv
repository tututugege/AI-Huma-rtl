// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::ub_track (commit-order fetch-block tracker, taken-path history mode)
`default_nettype none

// Follows the committed instruction stream and reconstructs the fetch block each instruction belonged to; produces the
// train events of the uBTB / L1 (one per commit lane at most), in program order.
//   new block: after a taken control instruction (at its target), after a conditional branch predicted taken but not
//   taken (at pc+4), at the block boundary, and at any pc discontinuity.
// Parallel form of the sequential lane loop.  The block start of lane i is one of a small set of candidates: the
// start after lane 0, the pc of a lane that follows a pc discontinuity (a local compare with the previous lane's next
// pc), or the next pc of a lane that ended a block.  The boundary compare of every lane is made against all of these
// candidates in parallel and "which candidate is current" is resolved with one single-bit step per lane.
// Lanes that are not valid are skipped, like in the sequential loop.
module bpu_ub_track import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [31:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [31:0]         target   [NCOMMIT],
  output logic [NCOMMIT-1:0]  ev_valid,
  output ub_ev_t              ev       [NCOMMIT]
);

  localparam logic [1:0] EV_TAKEN = 2'd0;
  localparam logic [1:0] EV_FALL  = 2'd1;
  localparam logic [1:0] EV_NTSLOT = 2'd2;
  // candidate block starts: state of the last cycle (0), next pc of lane j (j + 1), pc of lane i after a jump (8 + i)
  localparam int NS = 2 * NCOMMIT;
  localparam int PB = NCOMMIT;            // index of the first jump candidate

  logic        tr_v_q;
  logic [31:0] tr_start_q, tr_expect_q;
  logic        tr_cond_q;
  logic        tr_v_d;
  logic [31:0] tr_start_d, tr_expect_d;
  logic        tr_cond_d;

  // ---- lane-local facts ----
  logic [NCOMMIT-1:0] is_dir, taken, ntslot, nt_plain, jump;
  logic [31:0]        nxt     [NCOMMIT];
  logic [31:0]        next_pc [NCOMMIT];   // actual next pc of the lane
  logic [31:0]        exp_pc;
  logic               has_prev;
  logic [31:0]        cand    [NS];        // candidate block starts
  logic [31:0]        cand_bnd [NS];
  logic [NCOMMIT-1:0] bnd_hit [NS];        // lane i: nxt >= block end of candidate s

  // Ref: ub_track, per-lane decisions that do not depend on the block start
  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) begin
      is_dir[i]   = upd_valid[i] && (br_type[i] == BR_DIRECT);
      taken[i]    = upd_valid[i] && (br_type[i] != BR_NONCTL) && actual_dir[i];
      ntslot[i]   = upd_valid[i] && !taken[i] && (br_type[i] == BR_DIRECT) && pred_dir[i];
      nt_plain[i] = upd_valid[i] && !taken[i] && !ntslot[i];
      nxt[i]      = base_pc[i] + 32'd4;
      next_pc[i]  = taken[i] ? target[i] : nxt[i];
    end
    // discontinuity of every valid lane against the next pc of the previous valid lane (or the state of last cycle)
    exp_pc = tr_expect_q;
    has_prev = 1'b0;
    for (int i = 0; i < NCOMMIT; i++) begin
      jump[i] = upd_valid[i] && (has_prev ? base_pc[i] != exp_pc :
                                 (!tr_v_q || base_pc[i] != tr_expect_q || base_pc[i] >= block_bnd(tr_start_q)));
      if (upd_valid[i]) begin
        exp_pc   = next_pc[i];
        has_prev = 1'b1;
      end
    end
    cand[0] = tr_start_q;
    for (int j = 0; j < NCOMMIT - 1; j++) cand[j + 1] = next_pc[j];
    for (int i = 0; i < NCOMMIT; i++) cand[PB + i] = base_pc[i];
    for (int s = 0; s < NS; s++) begin
      cand_bnd[s] = block_bnd(cand[s]);
      for (int i = 0; i < NCOMMIT; i++) bnd_hit[s][i] = nxt[i] >= cand_bnd[s];
    end
  end

  // ---- resolve the block start of every lane ----
  logic [NS-1:0]      src      [NCOMMIT];   // one-hot: which candidate is the block start of lane i
  logic [NCOMMIT-1:0] boundary, change;
  logic [31:0]        lane_start [NCOMMIT];
  logic [NCOMMIT-1:0] cond_in;              // a conditional branch was seen in the block before this lane
  logic [NCOMMIT-1:0] cond_now;             // ... including this lane
  logic [NS-1:0]      hit_col  [NCOMMIT];   // hit_col[i][s] = bnd_hit[s][i]

  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) for (int s = 0; s < NS; s++) hit_col[i][s] = bnd_hit[s][i];
  end

  // Ref: ub_track: block end / block change chain, one single-bit step per lane
  always_comb begin
    logic [NS-1:0] cur;
    cur = NS'(1);
    for (int i = 0; i < NCOMMIT; i++) begin
      if (jump[i]) cur = NS'(1) << (PB + i);
      src[i]      = cur;
      boundary[i] = nt_plain[i] && (|(cur & hit_col[i]));
      change[i]   = taken[i] || ntslot[i] || boundary[i];
      if (change[i]) cur = NS'(1) << (i + 1);
    end
  end

  // block start and conditional flag of every lane
  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) begin
      lane_start[i] = '0;
      cond_in[i]    = 1'b0;
      for (int s = 0; s < NS; s++) begin
        if (src[i][s]) begin
          lane_start[i] = cand[s];
          if (s == 0) begin
            cond_in[i] = tr_cond_q;
            for (int m = 0; m < i; m++) cond_in[i] = cond_in[i] || is_dir[m];
          end else if (s < PB) begin                    // block starts at lane s
            for (int m = s; m < i; m++) cond_in[i] = cond_in[i] || is_dir[m];
          end else begin                                // block starts at lane s - PB (after a jump)
            for (int m = s - PB; m < i; m++) cond_in[i] = cond_in[i] || is_dir[m];
          end
        end
      end
      cond_now[i] = cond_in[i] || is_dir[i];
    end
  end

  // ---- events ----
  always_comb begin
    ev_valid = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      ev[i]       = '0;
      ev[i].start = lane_start[i][31:2];
      ev[i].slot  = 3'((base_pc[i] - lane_start[i]) >> 2);
      ev[i].ty    = br_type[i];
      if (taken[i]) begin
        ev_valid[i] = 1'b1; ev[i].kind = EV_TAKEN; ev[i].tgt = target[i][31:2];
      end else if (ntslot[i]) begin
        ev_valid[i] = 1'b1; ev[i].kind = EV_NTSLOT;
      end else if (boundary[i]) begin
        ev_valid[i] = cond_now[i]; ev[i].kind = EV_FALL;
      end
    end
  end

  // ---- state after the last valid lane ----
  logic [NCOMMIT-1:0] last;
  logic               any_valid;

  always_comb begin
    any_valid = |upd_valid;
    for (int i = 0; i < NCOMMIT; i++) last[i] = upd_valid[i] && !(|(upd_valid >> (i + 1)));
  end

  always_comb begin
    tr_v_d = tr_v_q; tr_start_d = tr_start_q; tr_expect_d = tr_expect_q; tr_cond_d = tr_cond_q;
    if (any_valid) begin
      tr_v_d = 1'b1;
      for (int i = 0; i < NCOMMIT; i++) begin
        if (last[i]) begin
          tr_start_d  = change[i] ? next_pc[i] : lane_start[i];
          tr_cond_d   = change[i] ? 1'b0 : cond_now[i];
          tr_expect_d = next_pc[i];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tr_v_q      <= 1'b0;
      tr_start_q  <= '0;
      tr_expect_q <= '0;
      tr_cond_q   <= 1'b0;
    end else begin
      tr_v_q      <= tr_v_d;
      tr_start_q  <= tr_start_d;
      tr_expect_q <= tr_expect_d;
      tr_cond_q   <= tr_cond_d;
    end
  end

endmodule

`default_nettype wire
