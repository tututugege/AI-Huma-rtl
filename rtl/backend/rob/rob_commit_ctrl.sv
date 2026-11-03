// Ref: back-end/Rob.cpp  class Rob  (comb_commit: group commit / single commit / forward-progress commit / interrupt)
`default_nettype none

module rob_commit_ctrl
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                     empty,
  input  logic                     mispred,               // dec_bcast.mispred: no commit this cycle
  input  logic                     front_stall,
  input  logic                     interrupt_req,
  input  logic                     committed_store_pending,
  input  logic [ROB_BANK_NUM-1:0]  head_valid,
  input  logic [ROB_BANK_NUM-1:0]  head_complete,
  input  logic [ROB_BANK_NUM-1:0]  head_flush,
  input  logic [ROB_BANK_NUM-1:0]  head_fence,
  input  logic [ROB_BANK_NUM-1:0]  head_wfi,
  output logic [ROB_BANK_NUM-1:0]  commit_valid,          // rob_commit.commit_entry[i].valid
  output logic                     single_commit,         // the commit is the first valid slot alone
  output logic [ROB_BANK_NUM-1:0]  first_valid,           // one-hot: first valid slot of the head line (single_idx)
  output logic                     interrupt_fire,
  output logic                     deq_advance            // head line fully retired: deq_ptr moves on
);

  logic has_head;                 // group_has_head
  logic all_complete;             // every valid slot of the head line is complete
  logic any_special;              // flush / fence / wfi instruction somewhere in the head line
  logic first_complete, first_fence, first_flush;
  logic group_ok;                 // C++ `commit` before the fence gate
  logic fence_gate;               // fence-class head blocked until the committed-store queue drains
  logic single_by_rule;           // single commit chosen by the special-instruction / interrupt rule
  logic single_progress;          // forward-progress single commit
  logic group_commit;

  ttg_first_set #(.N(ROB_BANK_NUM)) u_first_valid (
    .req(head_valid), .onehot(first_valid), .any(has_head)
  );

  // facts about the first valid slot (single_idx) and the whole line
  always_comb begin
    all_complete   = &(~head_valid | head_complete);
    any_special    = |(head_valid & (head_flush | head_fence | head_wfi));
    first_complete = |(first_valid & head_complete);
    first_fence    = |(first_valid & head_fence);
    first_flush    = |(first_valid & head_flush);
  end

  // Ref: Rob::comb_commit
  always_comb begin
    // group commit candidate (front_stall only back-pressures a line that really has something to commit)
    group_ok  = !empty && !mispred && !(has_head && front_stall) && all_complete;
    // fence / fence.i / sfence.vma wait for the committed stores to drain; this also cancels the group commit
    fence_gate = !mispred && !interrupt_req && has_head && first_fence && committed_store_pending;
    // single commit: interrupt (any head) or special instruction in the line whose first valid slot is complete
    single_by_rule = !mispred && has_head && (interrupt_req || (any_special && first_complete)) && !fence_gate;
    // forward progress: group blocked and no single commit, still retire the oldest complete non-flush instruction
    single_progress = !mispred && !(group_ok && !fence_gate) && !single_by_rule && !interrupt_req && has_head &&
                      first_complete && !first_flush;
    single_commit  = single_by_rule || single_progress;
    interrupt_fire = !mispred && interrupt_req && has_head;
    group_commit   = group_ok && !fence_gate && !single_commit;
    commit_valid   = group_commit ? head_valid : (single_commit ? first_valid : '0);
    // group commit drains the line by construction; single commit drains it only if no other valid slot is left
    deq_advance    = group_commit || (single_commit && ((head_valid & ~first_valid) == '0));
  end

endmodule

`default_nettype wire
