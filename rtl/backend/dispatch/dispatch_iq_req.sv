// Ref: back-end/Dispatch.cpp  Dispatch::comb_dispatch (req write) + comb_fire step 2 (rollback)
`default_nettype none

// Builds the per-IQ request ports: port s of IQ q carries the uop of the lane that was assigned that port
// and actually fired. (The C++ writes the requests in comb_dispatch and withdraws the ones whose lane
// did not fire in comb_fire; here only fired lanes ever drive a request.)
module dispatch_iq_req
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                 fire     [NUM_SLOTS],
  input  logic [IQ_NUM-1:0]    has_iq   [NUM_SLOTS],
  input  logic [IQ_PORT_W-1:0] port_idx [NUM_SLOTS][IQ_NUM],
  input  dis_iss_uop_t         uop_iq   [NUM_SLOTS][IQ_NUM],
  output logic                 req_valid [IQ_NUM][IQ_PORTS],
  output dis_iss_uop_t         req_uop   [IQ_NUM][IQ_PORTS]
);

  localparam int UOP_W = $bits(dis_iss_uop_t);

  for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
    logic [UOP_W-1:0] lane_uop [NUM_SLOTS];   // this IQ's uop of every lane
    always_comb begin
      for (int i = 0; i < NUM_SLOTS; i++) lane_uop[i] = uop_iq[i][q];
    end

    for (genvar s = 0; s < IQ_PORTS; s++) begin : g_port
      logic [NUM_SLOTS-1:0] owner;   // lane driving port s (at most one)
      logic [UOP_W-1:0]     owner_uop;
      always_comb begin
        for (int i = 0; i < NUM_SLOTS; i++) begin
          owner[i] = fire[i] && has_iq[i][q] && (port_idx[i][q] == IQ_PORT_W'(s));
        end
        req_valid[q][s] = |owner;
      end
      ttg_onehot_mux #(.N(NUM_SLOTS), .W(UOP_W)) u_mux (.sel(owner), .data(lane_uop), .out(owner_uop));
      always_comb req_uop[q][s] = dis_iss_uop_t'(owner_uop);
    end
  end

endmodule

`default_nettype wire
