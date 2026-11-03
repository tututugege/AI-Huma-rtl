// Ref: back-end/Dispatch.cpp  Dispatch::comb_fire (step 1: dis_fire and dis2ren.ready)
`default_nettype none

// Decides which lanes dispatch this cycle. Lanes fire in order; the first valid lane that cannot fire
// (resource, IQ full, ROB full, flush, serialisation) stalls every younger lane, and so does an
// AMO/WFI that fires (it dispatches alone, in its own cycle but together with older lanes).
// Parallel form of the C++ running pre_stall/pre_fire flags: "no stall so far" implies every older
// valid lane fired, so pre_fire is just "some older lane is valid".
module dispatch_fire_ctl
  import dis_pkg::*;
(
  input  logic       inst_valid  [NUM_SLOTS],
  input  logic       lsu_ok   [NUM_SLOTS],   // LSU entries granted
  input  logic       fit         [NUM_SLOTS],   // IQ ports available
  input  logic       is_csr_like [NUM_SLOTS],
  input  logic       is_amo      [NUM_SLOTS],
  input  logic       is_wfi      [NUM_SLOTS],
  input  logic       rob_ready,
  input  logic       rob_empty,
  input  logic       rob_stall,
  input  logic       rob_flush,
  input  logic       dec_mispred,
  output logic       dis_fire    [NUM_SLOTS],
  output logic       dis2ren_ready
);

  logic                 global_flush;
  logic [NUM_SLOTS-1:0] valid_vec;
  logic [NUM_SLOTS-1:0] stop_here;      // lane ends the fire group if reached un-stalled

  always_comb begin
    global_flush = rob_flush || dec_mispred || rob_stall;
    for (int i = 0; i < NUM_SLOTS; i++) valid_vec[i] = inst_valid[i];
  end

  logic fire_ideal [NUM_SLOTS];   // lane fires provided no older lane stalled

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    localparam logic [NUM_SLOTS-1:0] OLDER = NUM_SLOTS'((1 << i) - 1);
    logic serialize_block;
    // Ref: Dispatch::comb_fire step 1 (basic_fire, CSR / atomic serialisation)
    always_comb begin
      serialize_block = (is_csr_like[i] || is_amo[i]) && (!rob_empty || |(valid_vec & OLDER));
      fire_ideal[i]   = inst_valid[i] && lsu_ok[i] && fit[i] && rob_ready && !global_flush && !serialize_block;
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
