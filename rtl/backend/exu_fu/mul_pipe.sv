// Ref: back-end/Exu/include/AbstractFU.h  FixedLatencyFU (pipeline deque, comb_ctrl / comb_issue / comb_consume)
`default_nettype none

// In-order DEPTH-entry result pipeline of a fixed-latency FU (DEPTH = latency = MUL_MAX_LATENCY).  Entries are kept
// compacted at the low indices (index 0 = oldest).  Only the oldest entry can complete / be consumed.  Per cycle:
//   1. kill      : flush removes entries (all of them for an all-ones flush_mask, else those sharing a flush_mask bit)
//   2. clear     : clear_mask bits are removed from the surviving entries' br_mask
//   3. accept    : en pushes a new entry if the pipe is not full *before* this cycle's pop
//   4. complete  : the oldest survivor has waited its latency (rem == 0); consume pops it
//   5. ready     : the pipe is not full after pop and accept
// `rem` is the C++ `done_cycle - sim_time`: it is LAT-2 in the cycle after an entry is pushed (done = push + LAT - 1)
// and counts down to 0, where it stays (a finished entry remains finished until consumed).
module mul_pipe
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int DEPTH = MUL_MAX_LATENCY
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,
  input  logic [BR_MASK_WIDTH-1:0] flush_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  input  logic                     en,
  input  logic                     consume,
  input  fu_uop_t                  en_uop,
  output logic                     complete,
  output logic                     ready,
  output fu_uop_t                  done_uop
);

  localparam int RW = $clog2(DEPTH);
  localparam int UW = $bits(fu_uop_t);
  localparam int EW = UW + RW;                 // one stored entry = {uop, rem}
  localparam logic [RW-1:0] REM_NEW = RW'(DEPTH - 2);

`ifndef SYNTHESIS
  if (DEPTH < 2) begin : g_depth_check
    $error("mul_pipe: latency must be >= 2 (a latency-1 FU would complete in its accept cycle)");
  end
`endif

  // ---- state ----
  logic [DEPTH-1:0] valid_q, valid_d;
  fu_uop_t          uop_q [DEPTH];
  fu_uop_t          uop_d [DEPTH];
  logic [RW-1:0]    rem_q [DEPTH];
  logic [RW-1:0]    rem_d [DEPTH];

  // ---- kill / clear / complete ----
  logic [DEPTH-1:0] kill, surv, ripe;
  fu_uop_t          uop_c [DEPTH];            // survivors with clear_mask applied
  logic [UW-1:0]    uop_c_bits [DEPTH];
  logic [RW-1:0]    rem_n [DEPTH];            // rem one cycle later
  logic             flush_all;

  // Ref: FixedLatencyFU::comb_ctrl
  always_comb begin
    flush_all = &flush_mask;
    for (int i = 0; i < DEPTH; i++) begin
      kill[i]  = valid_q[i] && flush && (flush_all || (|(uop_q[i].br_mask & flush_mask)));
      surv[i]  = valid_q[i] && !kill[i];
      ripe[i]  = (rem_q[i] == '0);
      rem_n[i] = ripe[i] ? '0 : rem_q[i] - RW'(1);
      uop_c[i]         = uop_q[i];
      uop_c[i].br_mask = uop_q[i].br_mask & ~clear_mask;
      uop_c_bits[i]    = UW'(uop_c[i]);
    end
  end

  logic [DEPTH-1:0] front_oh, keep;
  logic             any_surv, front_ripe, pop;
  logic [UW-1:0]    done_bits;

  ttg_first_set #(.N(DEPTH)) u_front (.req(surv), .onehot(front_oh), .any(any_surv));
  ttg_onehot_mux #(.N(DEPTH), .W(UW)) u_done (.sel(front_oh), .data(uop_c_bits), .out(done_bits));

  // Ref: FixedLatencyFU::comb_issue (complete) / comb_consume (pop)
  always_comb begin
    front_ripe = |(front_oh & ripe);
    complete   = any_surv && front_ripe;
    pop        = consume && complete;
    keep       = surv & ~(front_oh & {DEPTH{pop}});
    done_uop   = fu_uop_t'(done_bits);
  end

  // ---- accept / ready ----
  logic                       accept;
  logic [$clog2(DEPTH+1)-1:0] n_keep, n_next;

  ttg_popcount #(.N(DEPTH)) u_nkeep (.bits(keep), .count(n_keep));

  always_comb begin
    accept = en && !(&surv);                        // limit is checked before the pop
    n_next = n_keep + ($bits(n_keep))'(accept);
    ready  = n_next < ($bits(n_next))'(DEPTH);
  end

  // ---- next state: survivors compact down by the number of removed entries below them; the new entry goes last ----
  localparam int CW = $clog2(DEPTH + 1);
  logic [EW-1:0]  src_ent [DEPTH+1];             // source i for the next-state muxes (i = DEPTH is the new entry)
  logic [DEPTH:0] sel     [DEPTH];               // sel[j][i]: destination j takes source i
  logic [EW-1:0]  nxt     [DEPTH];
  logic [CW-1:0]  rank    [DEPTH];               // number of kept entries below entry i = its new index

  for (genvar i = 0; i < DEPTH; i++) begin : g_rank
    localparam logic [DEPTH-1:0] BELOW = (DEPTH'(1) << i) - DEPTH'(1);
    ttg_popcount #(.N(DEPTH)) u_rank (.bits(keep & BELOW), .count(rank[i]));
  end

  always_comb begin
    for (int i = 0; i < DEPTH; i++) src_ent[i] = {uop_c_bits[i], rem_n[i]};
    src_ent[DEPTH] = {UW'(en_uop), REM_NEW};
  end

  for (genvar j = 0; j < DEPTH; j++) begin : g_dst
    always_comb begin
      for (int i = 0; i < DEPTH; i++) sel[j][i] = keep[i] && (rank[i] == CW'(j));
      sel[j][DEPTH] = accept && (n_keep == CW'(j));
    end
    ttg_onehot_mux #(.N(DEPTH + 1), .W(EW)) u_nxt (.sel(sel[j]), .data(src_ent), .out(nxt[j]));
    always_comb begin
      valid_d[j] = |sel[j];
      {uop_d[j], rem_d[j]} = nxt[j];  // struct <- bit slice
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
      for (int i = 0; i < DEPTH; i++) begin
        uop_q[i] <= '0;
        rem_q[i] <= '0;
      end
    end else begin
      valid_q <= valid_d;
      for (int i = 0; i < DEPTH; i++) begin
        uop_q[i] <= uop_d[i];
        rem_q[i] <= rem_d[i];
      end
    end
  end

endmodule

`default_nettype wire
