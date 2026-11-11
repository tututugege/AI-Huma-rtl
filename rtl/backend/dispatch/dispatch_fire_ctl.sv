// Ref: back-end/Dispatch.cpp  Dispatch::comb_fire (step 1: dis_fire and dis2ren.ready)
`default_nettype none

// Decides which lanes dispatch this cycle. Lanes fire in order; the first valid lane that cannot fire
// (resource, IQ full, ROB full, flush, serialisation) stalls every younger lane, and so does an
// AMO/WFI that fires (it dispatches alone, in its own cycle but together with older lanes).
// Parallel form of the C++ running pre_stall/pre_fire flags: "no stall so far" implies every older
// valid lane fired, so pre_fire is just "some older lane is valid".
module dispatch_fire_ctl
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic [NUM_SLOTS-1:0] inst_valid,
  input  logic [NUM_SLOTS-1:0] lsu_ok,   // LSU entries granted
  input  logic [NUM_SLOTS-1:0] fit,   // IQ ports available
  input  logic [NUM_SLOTS-1:0] is_csr_like,
  input  logic [NUM_SLOTS-1:0] is_amo,
  input  logic [NUM_SLOTS-1:0] is_wfi,
  input  logic       rob_ready,
  input  logic [ROB_IDX_WIDTH:0] rob_free,   // compact ROB (EXP-028): free entries; a lane fires only if its rank among
                                             // the valid lanes is below it (line ROB: unused)
  input  logic       rob_empty,
  input  logic       rob_stall,
  input  logic       rob_flush,
  input  logic       dec_mispred,
  output logic [NUM_SLOTS-1:0] dis_fire,
  output logic       dis2ren_ready
);

  logic                 global_flush;
  logic [NUM_SLOTS-1:0] valid_vec;
  logic [NUM_SLOTS-1:0] stop_here;      // lane ends the fire group if reached un-stalled

  always_comb begin
    global_flush = rob_flush || dec_mispred || rob_stall;
    for (int i = 0; i < NUM_SLOTS; i++) valid_vec[i] = inst_valid[i];
  end

  logic [NUM_SLOTS-1:0] fire_ideal;   // lane fires provided no older lane stalled
  logic [NUM_SLOTS-1:0] rob_fit;      // Ref: Dispatch::comb_fire rob_used < rob2dis.free_cnt (compact ROB)

  always_comb begin
    int unsigned used;
    used = 0;
    for (int i = 0; i < NUM_SLOTS; i++) begin
      rob_fit[i] = (ROB_COMPACT == 0) || ((ROB_IDX_WIDTH+1)'(used) < rob_free);
      used = used + (inst_valid[i] ? 1 : 0);
    end
  end

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    localparam logic [NUM_SLOTS-1:0] OLDER = NUM_SLOTS'((1 << i) - 1);
    logic serialize_block;
    // Ref: Dispatch::comb_fire step 1 (basic_fire, CSR / atomic serialisation)
    always_comb begin
      serialize_block = (is_csr_like[i] || is_amo[i]) && (!rob_empty || |(valid_vec & OLDER));
      fire_ideal[i]   = inst_valid[i] && lsu_ok[i] && fit[i] && rob_ready && !global_flush && !serialize_block &&
                        rob_fit[i];
      stop_here[i]    = inst_valid[i] && (!fire_ideal[i] || is_amo[i] || is_wfi[i]);
      dis_fire[i]     = fire_ideal[i] && !(|(stop_here & OLDER));
    end
  end

  // Ref: Dispatch::comb_fire "out.dis2ren->ready = !pre_stall"
  always_comb begin
    dis2ren_ready = !(|stop_here);
  end

endmodule

`default_nettype wire
