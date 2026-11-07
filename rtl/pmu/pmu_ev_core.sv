// Ref: (new, EXP-013) pmu -- event bus, tier 1: retirement stream, redirects and the dispatch slots (top-down level 1)
// Builds the lanes of the event bus from the commit slots and the redirect/flush signals of the
// back end. Lanes of events that are not wired yet stay zero (see trace-model include/pmu_events.def, "RTL tier 1").
// Same definitions as the trace-model: an interrupt slot does not count as a retired instruction, every AMO counts as
// a load and a store, a mispredict is a branch redirect that is not a flush.
`default_nettype none

module pmu_ev_core
  import pmu_ev_pkg::*;
#(
  parameter int COMMIT_W  = 8,
  parameter int TYPE_W    = 5
) (
  input  logic                                 clk,
  input  logic                                 rst_n,
  input  logic [COMMIT_W-1:0]                  slot_valid,      // dispatch stage holds an instruction in this slot
  input  logic [COMMIT_W-1:0]                  slot_fire,       // the slot dispatched this cycle
  input  logic [COMMIT_W-1:0]                  commit_valid,
  input  logic [TYPE_W-1:0]                    commit_type [COMMIT_W],
  input  logic                                 interrupt,       // this cycle's commit is an interrupt response
  input  logic                                 flush,
  input  logic                                 exception,
  input  logic                                 redirect,        // back-end redirect output (a flush also raises it)
  output logic [PMU_NUM_EV-1:0][PMU_INC_W-1:0] ev_inc
);

  // instruction types (ren_pkg / rob_pkg ITYPE_*)
  localparam logic [TYPE_W-1:0] T_JAL   = TYPE_W'(1);
  localparam logic [TYPE_W-1:0] T_JALR  = TYPE_W'(2);
  localparam logic [TYPE_W-1:0] T_BR    = TYPE_W'(4);
  localparam logic [TYPE_W-1:0] T_LOAD  = TYPE_W'(5);
  localparam logic [TYPE_W-1:0] T_STORE = TYPE_W'(6);
  localparam logic [TYPE_W-1:0] T_AMO   = TYPE_W'(18);
  localparam int                CW      = $clog2(COMMIT_W + 1);

  logic [COMMIT_W-1:0] retire, is_load, is_store, is_branch, is_jump;
  always_comb begin
    for (int i = 0; i < COMMIT_W; i++) begin
      retire[i]    = commit_valid[i] && !interrupt;
      is_load[i]   = retire[i] && (commit_type[i] == T_LOAD || commit_type[i] == T_AMO);
      is_store[i]  = retire[i] && (commit_type[i] == T_STORE || commit_type[i] == T_AMO);
      is_branch[i] = retire[i] && (commit_type[i] == T_BR);
      is_jump[i]   = retire[i] && (commit_type[i] == T_JAL || commit_type[i] == T_JALR);
    end
  end

  logic [CW-1:0] n_retire, n_load, n_store, n_branch, n_jump;
  ttg_popcount #(.N(COMMIT_W)) u_pc_retire (.bits(retire),    .count(n_retire));
  ttg_popcount #(.N(COMMIT_W)) u_pc_load   (.bits(is_load),   .count(n_load));
  ttg_popcount #(.N(COMMIT_W)) u_pc_store  (.bits(is_store),  .count(n_store));
  ttg_popcount #(.N(COMMIT_W)) u_pc_branch (.bits(is_branch), .count(n_branch));
  ttg_popcount #(.N(COMMIT_W)) u_pc_jump   (.bits(is_jump),   .count(n_jump));

  // ---- top-down slots (dispatch stage; slots = COMMIT_W) ----
  // every slot is in exactly one bucket: fired | killed (flush/mispredict cycle) | backend-stalled (from the first
  // valid slot that did not fire, on) | empty (frontend; "recovery" while refilling after a redirect, until the
  // first instruction is back at dispatch)
  logic kill, recovering_q, recovering_d, recov_flush_q, recov_flush_d, recov_now, recov_by_flush;
  logic [COMMIT_W-1:0] blocked, killed, empty;
  always_comb begin
    kill = redirect;                     // a flush also raises the redirect
    blocked = '0;
    for (int i = 0; i < COMMIT_W; i++)
      blocked[i] = !kill && ((i > 0 && blocked[(i > 0) ? i - 1 : 0]) || (slot_valid[i] && !slot_fire[i]));
    killed = slot_valid & ~slot_fire & {COMMIT_W{kill}};
    empty  = ~slot_fire & ~killed & ~blocked;
    recov_now      = recovering_q || kill;
    recov_by_flush = kill ? flush : recov_flush_q;
    recovering_d   = recovering_q;
    recov_flush_d  = recov_flush_q;
    if (kill) begin
      recovering_d  = 1'b1;
      recov_flush_d = flush;
    end else if (|slot_valid) begin
      recovering_d  = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      recovering_q  <= 1'b0;
      recov_flush_q <= 1'b0;
    end else begin
      recovering_q  <= recovering_d;
      recov_flush_q <= recov_flush_d;
    end
  end

  logic [CW-1:0] n_fire, n_killed, n_blocked, n_empty;
  ttg_popcount #(.N(COMMIT_W)) u_pc_fire    (.bits(slot_fire), .count(n_fire));
  ttg_popcount #(.N(COMMIT_W)) u_pc_killed  (.bits(killed),    .count(n_killed));
  ttg_popcount #(.N(COMMIT_W)) u_pc_blocked (.bits(blocked),   .count(n_blocked));
  ttg_popcount #(.N(COMMIT_W)) u_pc_empty   (.bits(empty),     .count(n_empty));

  always_comb begin
    ev_inc = '0;
    ev_inc[PMU_EV_SLOT_FIRE]          = PMU_INC_W'(n_fire);
    ev_inc[PMU_EV_SLOT_KILLED]        = PMU_INC_W'(n_killed);
    ev_inc[PMU_EV_SLOT_FE_EMPTY]      = PMU_INC_W'(n_empty);
    if (recov_now) begin
      ev_inc[PMU_EV_SLOT_FE_RECOV_FLUSH]   = recov_by_flush ? PMU_INC_W'(n_empty) : '0;
      ev_inc[PMU_EV_SLOT_FE_RECOV_MISPRED] = recov_by_flush ? '0 : PMU_INC_W'(n_empty);
    end
    ev_inc[PMU_EV_SLOT_BE]            = PMU_INC_W'(n_blocked);
    ev_inc[PMU_EV_CYC_RECOVERING]     = PMU_INC_W'(recovering_q);
    ev_inc[PMU_EV_CYCLES]          = PMU_INC_W'(1);
    ev_inc[PMU_EV_INSTRET]         = PMU_INC_W'(n_retire);
    ev_inc[PMU_EV_COMMIT_LOAD]     = PMU_INC_W'(n_load);
    ev_inc[PMU_EV_COMMIT_STORE]    = PMU_INC_W'(n_store);
    ev_inc[PMU_EV_COMMIT_BRANCH]   = PMU_INC_W'(n_branch);
    ev_inc[PMU_EV_COMMIT_JUMP]     = PMU_INC_W'(n_jump);
    ev_inc[PMU_EV_CYC_COMMIT_ZERO] = PMU_INC_W'(n_retire == CW'(0));
    ev_inc[PMU_EV_CYC_COMMIT_FULL] = PMU_INC_W'(n_retire == CW'(COMMIT_W));
    ev_inc[PMU_EV_BR_MISPRED]      = PMU_INC_W'(redirect && !flush);
    ev_inc[PMU_EV_FLUSH_EXCEPTION] = PMU_INC_W'(flush && exception);
    ev_inc[PMU_EV_FLUSH_OTHER]     = PMU_INC_W'(flush && !exception);
  end

endmodule

`default_nettype wire
