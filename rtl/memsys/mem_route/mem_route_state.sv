// Ref: MemSubSystem/MemRouteBlock.cpp  MemRouteBlockState (cur/nxt), MemRouteBlock::seq
`default_nettype none

// State registers of the route block; they update only on cpu_en (the CPU-phase tick, tick 0 of the 16-tick cycle).
module mem_route_state import ttg_cfg_pkg::*; import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  // next-state inputs from the combinational blocks
  input  route_owner_e              owner_d,          // owner granted this cycle (NONE if nobody): becomes issued_owner
  input  logic                      ptw_wait_d,
  input  logic                      route_hi_d,       // address bit 2 of the route request of this cycle
  input  logic                      lsu_replay_valid_d,
  input  logic [LD_ID_W-1:0]        lsu_replay_id_d,
  // current state
  output route_owner_e              issued_owner_q,   // owner of last cycle's request (its response arrives now)
  output logic [RT_ID_W-1:0]        issued_id_q,
  output logic                      issued_hi_q,
  output logic [RT_ID_W-1:0]        next_id_q,        // id of the next route request
  output logic                      ptw_wait_q,       // walk request waits for an MSHR fill
  output logic                      lsu_replay_valid_q,
  output logic [LD_ID_W-1:0]        lsu_replay_id_q
);

  // the id / replay-record registers only move when a route request is granted (C++: inside `if (ptw_owner != NONE)`)
  wire granted = owner_d != OWN_NONE;

  logic [RT_ID_W-1:0] issued_id_d;
  logic [RT_ID_W-1:0] next_id_d;
  logic               lsu_replay_valid_n;
  logic [LD_ID_W-1:0] lsu_replay_id_n;

  always_comb begin
    issued_id_d        = granted ? next_id_q : issued_id_q;
    next_id_d          = granted ? next_id_q + RT_ID_W'(1) : next_id_q;
    lsu_replay_valid_n = granted ? lsu_replay_valid_d : lsu_replay_valid_q;
    lsu_replay_id_n    = granted ? lsu_replay_id_d : lsu_replay_id_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      issued_owner_q     <= OWN_NONE;
      issued_id_q        <= '0;
      issued_hi_q        <= 1'b0;
      next_id_q          <= '0;
      ptw_wait_q         <= 1'b0;
      lsu_replay_valid_q <= 1'b0;
      lsu_replay_id_q    <= '0;
    end else if (cpu_en) begin
      issued_owner_q     <= owner_d;
      issued_id_q        <= issued_id_d;
      issued_hi_q        <= granted ? route_hi_d : issued_hi_q;
      next_id_q          <= next_id_d;
      ptw_wait_q         <= ptw_wait_d;
      lsu_replay_valid_q <= lsu_replay_valid_n;
      lsu_replay_id_q    <= lsu_replay_id_n;
    end
  end

endmodule

`default_nettype wire
