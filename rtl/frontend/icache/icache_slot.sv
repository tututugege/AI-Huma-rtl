// Ref: front-end/icache/icache_module.cpp  ICache::lookup (request slot), eval_state_machine pass 1 (mmu_req)
`default_nettype none

// Registered request slot (single entry) and the ITLB request.
//   accept: a presented fetch is registered when the FSM can take it and the slot is empty and the FSM is at rest;
//   the slot is emptied as soon as the FSM answers it (req_ready) and kept while it waits (miss, translation pending).
//   mmu_req: the ITLB is asked for the page of the registered request every cycle it is valid (whatever the FSM
// state), or
//   for the presented fetch when it can be accepted.  It does not depend on the ITLB answer (no loop).
module icache_slot import icache_pkg::*; (
  input  logic                    r_req_valid,
  input  logic [31:0]             r_req_pc,
  input  ic_state_e               r_state,
  input  logic                    r_miss_txv,
  input  logic                    kill,           // refetch | fence.i
  input  logic                    req_valid_in,
  input  logic [31:0]             pc,
  input  logic                    req_ready,      // FSM answer this cycle (non-kill)
  input  logic                    fast_fire,
  output logic                    req_valid_d,
  output logic [31:0]             req_pc_d,
  output logic                    ifu_ready_d,
  output logic                    mmu_req_valid,
  output logic [19:0]             mmu_req_vtag
);

  logic slot_idle, can_accept;

  always_comb begin
    slot_idle  = !r_req_valid && r_state == IC_IDLE && !r_miss_txv;
    can_accept = req_valid_in && req_ready && slot_idle;
    req_valid_d = r_req_valid;
    req_pc_d    = r_req_pc;
    ifu_ready_d = 1'b0;
    if (fast_fire) begin
      req_valid_d = 1'b0;
      ifu_ready_d = 1'b1;
    end else begin
      if (can_accept)      req_valid_d = 1'b1;
      else if (req_ready)  req_valid_d = 1'b0;
      if (can_accept)      req_pc_d = pc;
      ifu_ready_d = req_ready && !req_valid_d;
    end
    mmu_req_valid = !kill && (r_req_valid || (req_valid_in && slot_idle));
    mmu_req_vtag  = r_req_valid ? r_req_pc[31:12] : pc[31:12];
  end

endmodule

`default_nettype wire
