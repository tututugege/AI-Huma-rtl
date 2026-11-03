// Ref: back-end/Dispatch.cpp  Dispatch::comb_dispatch (IQ capacity check and request-slot assignment)
`default_nettype none

// Issue-queue port allocation. Each IQ accepts up to min(dispatch_width, ready_num) uops per cycle;
// the lanes' uops for one IQ occupy its request ports 0,1,2... in lane order. A lane "fits" when every
// IQ it targets still has a free port after all older lanes took theirs. The first valid lane that does
// not fit ends the usable group (brk_before marks every lane after it).
module dispatch_iq_alloc
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                         inst_valid [NUM_SLOTS],
  input  logic [IQ_NUM-1:0]            has_iq     [NUM_SLOTS],
  input  logic [IQ_READY_NUM_WIDTH-1:0] ready_num [IQ_NUM],
  output logic [IQ_PORT_W-1:0]         port_idx   [NUM_SLOTS][IQ_NUM],  // request port of lane's uop in IQ q
  output logic                         fit        [NUM_SLOTS],          // lane fits (older lanes assumed fit)
  output logic                         brk_before [NUM_SLOTS]           // an older valid lane did not fit
);

  localparam int CNT_W = $clog2(NUM_SLOTS + 1);

  logic [NUM_SLOTS-1:0] want_iq [IQ_NUM];     // valid lanes that send a uop to IQ q
  logic [CNT_W-1:0]     used    [NUM_SLOTS][IQ_NUM];   // uops older lanes already put into IQ q
  logic                 iq_room [NUM_SLOTS][IQ_NUM];   // IQ q still has a port for this lane
  logic [NUM_SLOTS-1:0] valid_nofit;

  always_comb begin
    for (int q = 0; q < IQ_NUM; q++) begin
      for (int i = 0; i < NUM_SLOTS; i++) want_iq[q][i] = inst_valid[i] && has_iq[i][q];
    end
  end

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    localparam logic [NUM_SLOTS-1:0] OLDER = NUM_SLOTS'((1 << i) - 1);
    for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
      ttg_popcount #(.N(NUM_SLOTS)) u_used (.bits(want_iq[q] & OLDER), .count(used[i][q]));
      // Ref: Dispatch::comb_dispatch "iq_usage >= port_limit || iq_usage >= ready_num"
      always_comb begin
        iq_room[i][q] = (used[i][q] < CNT_W'(IQ_DISPATCH_WIDTH)) &&
                        ({{(IQ_READY_NUM_WIDTH-CNT_W){1'b0}}, used[i][q]} < ready_num[q]);
        port_idx[i][q] = used[i][q][IQ_PORT_W-1:0];
      end
    end
    always_comb begin
      fit[i] = 1'b1;
      for (int q = 0; q < IQ_NUM; q++) fit[i] = fit[i] && (!has_iq[i][q] || iq_room[i][q]);
      if (!inst_valid[i]) fit[i] = 1'b1;
      valid_nofit[i] = inst_valid[i] && !fit[i];
      brk_before[i]  = |(valid_nofit & OLDER);
    end
  end

endmodule

`default_nettype wire
