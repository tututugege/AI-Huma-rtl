// Ref: back-end/Dispatch.cpp  class Dispatch  (inst_r/inst_valid, comb_pipeline, seq)
`default_nettype none

// Dispatch input register stage: one renamed instruction per lane. Holds the group that is trying to
// dispatch; takes a new group from rename whenever dispatch reports ready, keeps (and updates) the
// un-fired instructions otherwise, and is emptied by a flush / branch mispredict.
module dispatch_inst_stage
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       kill,        // rob_bcast.flush | dec_bcast.mispred
  input  logic                       ready,       // dis2ren.ready: accept a new group from rename
  input  logic [BR_MASK_WIDTH-1:0]   clear_mask,  // resolved-branch bits to drop from every br_mask
  input  logic [NUM_SLOTS-1:0] ren_valid,
  input  dis_inst_t                  ren_inst  [NUM_SLOTS],
  input  logic [NUM_SLOTS-1:0] fire,
  input  logic [NUM_SLOTS-1:0] alloc_src1_busy,  // busy after comb_wake
  input  logic [NUM_SLOTS-1:0] alloc_src2_busy,
  input  logic [NUM_SLOTS-1:0] woken1,        // src preg woken by this cycle's wakeups
  input  logic [NUM_SLOTS-1:0] woken2,
  output logic [NUM_SLOTS-1:0] valid_q,
  output dis_inst_t                  inst_q    [NUM_SLOTS]
);

  logic [NUM_SLOTS-1:0] valid_d;
  dis_inst_t inst_d  [NUM_SLOTS];

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    logic      held_valid;   // instruction stays because it did not fire this cycle
    dis_inst_t held_inst;    // ... with busy bits refreshed by the wakeups of this cycle
    dis_inst_t new_inst;     // incoming rename instruction with resolved branch bits removed

    // Ref: Dispatch::comb_pipeline (ready == 0 branch: busy from inst_alloc, then apply_wakeup_to_uop)
    always_comb begin
      held_valid = valid_q[i] && !fire[i];
      held_inst  = inst_q[i];
      held_inst.src1_busy = alloc_src1_busy[i] && !(inst_q[i].src1_en && woken1[i]);
      held_inst.src2_busy = alloc_src2_busy[i] && !(inst_q[i].src2_en && woken2[i]);
      held_inst.br_mask   = inst_q[i].br_mask & ~clear_mask;
      new_inst = ren_inst[i];
      new_inst.br_mask = ren_inst[i].br_mask & ~clear_mask;
    end

    // Ref: Dispatch::comb_pipeline. Payload is only meaningful while valid: always take the new group
    // when ready, else the refreshed held payload; flush/mispred just drops valid.
    always_comb begin
      valid_d[i] = !kill && (ready ? ren_valid[i] : held_valid);
      inst_d[i]  = ready ? new_inst : held_inst;
    end
  end

  // Ref: Dispatch::seq
  always_ff @(posedge clk) begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      if (!rst_n) begin
        valid_q[i] <= 1'b0;
        inst_q[i]  <= '0;
      end else begin
        valid_q[i] <= valid_d[i];
        inst_q[i]  <= inst_d[i];
      end
    end
  end

endmodule

`default_nettype wire
