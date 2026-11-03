// Ref: back-end/Dispatch.cpp  Dispatch::comb_dispatch (IQ capacity check and request-slot assignment)
`default_nettype none

// Issue-queue port allocation. Each IQ accepts up to ready_num uops per cycle (the 8-port width limit
// is implied: at most 8 lanes). The uops of the lanes for one IQ occupy request ports 0,1,2... in lane
// order. A lane "fits" when every IQ it targets still has a free port after the older lanes took theirs.
// Only the fit of lanes whose older lanes all fit is ever consumed (a lane that fires needs that), so no
// break/ordering bookkeeping is needed here.
module dispatch_iq_alloc
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                         inst_valid [NUM_SLOTS],
  input  logic [IQ_NUM-1:0]            has_iq     [NUM_SLOTS],
  input  logic [IQ_READY_NUM_WIDTH-1:0] ready_num [IQ_NUM],
  output logic [IQ_PORT_W-1:0]         port_idx   [NUM_SLOTS][IQ_NUM],  // request port of lane's uop in IQ q
  output logic                         fit        [NUM_SLOTS]           // every targeted IQ has room
);

  localparam int CNT_W = $clog2(NUM_SLOTS + 1);

  logic [NUM_SLOTS-1:0] want_iq [IQ_NUM];     // valid lanes that send a uop to IQ q
  logic [CNT_W-1:0]     used    [NUM_SLOTS][IQ_NUM];   // uops older lanes already put into IQ q

  always_comb begin
    for (int q = 0; q < IQ_NUM; q++) begin
      for (int i = 0; i < NUM_SLOTS; i++) want_iq[q][i] = inst_valid[i] && has_iq[i][q];
    end
  end

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    localparam logic [NUM_SLOTS-1:0] OLDER = NUM_SLOTS'((1 << i) - 1);
    logic [IQ_NUM-1:0] room;   // IQ q still has a port for this lane
    for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
      ttg_popcount #(.N(NUM_SLOTS)) u_used (.bits(want_iq[q] & OLDER), .count(used[i][q]));
      always_comb begin
        room[q] = ({{(IQ_READY_NUM_WIDTH-CNT_W){1'b0}}, used[i][q]} < ready_num[q]);
        port_idx[i][q] = used[i][q][IQ_PORT_W-1:0];
      end
    end
    always_comb fit[i] = &(room | ~has_iq[i]);
  end

endmodule

`default_nettype wire
