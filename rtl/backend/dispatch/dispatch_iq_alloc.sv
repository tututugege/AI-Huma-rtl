// Ref: back-end/Dispatch.cpp  Dispatch::comb_dispatch (IQ capacity check and request-slot assignment)
`default_nettype none

// Issue-queue port allocation. Each IQ accepts up to ready_num uops per cycle (the 8-port width limit
// is implied: at most 8 lanes). The uops of the lanes for one IQ occupy request ports 0,1,2... in lane
// order. A lane "fits" when every IQ it targets still has room for all the uops the lane sends there after
// the older lanes took theirs (a lane sends at most one uop to a queue, except the AMO to the memory queue:
// LD + STA). Only the fit of lanes whose older lanes all fit is ever consumed (a lane that fires needs that),
// so no break/ordering bookkeeping is needed here.
module dispatch_iq_alloc
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic [NUM_SLOTS-1:0] inst_valid,
  input  logic [1:0]                   cnt_iq     [NUM_SLOTS][IQ_NUM],  // uops lane i sends to IQ q
  input  logic [IQ_READY_NUM_WIDTH-1:0] ready_num [IQ_NUM],
  output logic [IQ_PORT_W-1:0]         port_idx   [NUM_SLOTS][IQ_NUM],  // request port of lane's first uop in IQ q
  output logic [NUM_SLOTS-1:0] fit           // every targeted IQ has room
);

  localparam int CNT_W = $clog2(2 * NUM_SLOTS + 1);

  logic [CNT_W-1:0] used [NUM_SLOTS][IQ_NUM];   // uops older lanes already put into IQ q

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      for (int q = 0; q < IQ_NUM; q++) begin
        used[i][q] = '0;
        for (int j = 0; j < i; j++) if (inst_valid[j]) used[i][q] = used[i][q] + CNT_W'(cnt_iq[j][q]);
        port_idx[i][q] = used[i][q][IQ_PORT_W-1:0];
      end
    end
  end

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    logic [IQ_NUM-1:0] room;   // IQ q still has room for this lane's uops
    for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
      always_comb begin
        room[q] = (cnt_iq[i][q] == 2'd0) ||
                  (({{(IQ_READY_NUM_WIDTH-CNT_W+1){1'b0}}, used[i][q]} + (IQ_READY_NUM_WIDTH+1)'(cnt_iq[i][q])) <=
                   {1'b0, ready_num[q]});
      end
    end
    always_comb fit[i] = &room;
  end

endmodule

`default_nettype wire
