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
  input  logic [NUM_SLOTS-1:0] ren_valid,
  input  dis_inst_t                  ren_inst  [NUM_SLOTS],
  input  logic [NUM_SLOTS-1:0] fire,
  output logic [NUM_SLOTS-1:0] valid_q,
  output dis_inst_t                  inst_q    [NUM_SLOTS]
);

  logic [NUM_SLOTS-1:0] valid_d;
  dis_inst_t inst_d  [NUM_SLOTS];

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    logic      held_valid;   // instruction stays because it did not fire this cycle
    dis_inst_t held_inst;
    dis_inst_t new_inst;     // incoming rename instruction with resolved branch bits removed

    // Ref: Dispatch::comb_pipeline (held lanes keep inst_q; busy is re-derived next cycle)
    always_comb begin
      held_valid = valid_q[i] && !fire[i];
      held_inst  = inst_q[i];
      new_inst = ren_inst[i];
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
