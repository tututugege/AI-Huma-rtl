// Ref: front-end/icache/icache_module.cpp  ICache::eval_state_machine / lookup (the kill_pipe = io.in.refetch branches)
`default_nettype none

// "Kill" step K: what one I-cache evaluation does when the request pipe is cancelled (refetch, fence.i, or the second
// call of a predecode-flush cycle with invalidate_req).  Pure function of the control registers r and the AXI/DCache
// port values: nothing here touches the arrays, the ITLB or the 512-bit data registers.
//   - the registered request is dropped and the next cycle's icache_ready is held low;
//   - a miss in flight is abandoned: if its AXI request already left (or is accepted right now) its id is marked
//     "canceled" so the late response is dropped; if the master port showed ready but the accept pulse is still
//     outstanding the FSM waits one cycle for it (CANCEL_WAIT); otherwise everything is simply released;
//   - in SWAP_IN the DCache probe is stepped first (reference behaviour: it may issue a probe request in this
// very cycle).
module icache_kill import icache_pkg::*; (
  input  ic_regs_t                r,
  input  logic                    mem_req_ready,
  input  logic                    mem_req_accepted,
  input  logic [IC_TXID_W-1:0]    mem_req_accepted_id,
  input  logic                    mem_resp_valid,
  input  logic [IC_TXID_W-1:0]    mem_resp_id,
  output ic_regs_t                r_n,
  output logic                    mem_resp_ready,
  output logic                    dc_req_valid,
  output logic [31:0]             dc_req_addr
);

  logic drop_resp;
  /* verilator lint_off UNUSEDSIGNAL */  // icache_txn output not needed by K
  logic active_resp_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [IC_TXID_N-1:0] drop_mask;

  icache_txn u_txn (
    .resp_valid(mem_resp_valid), .resp_id(mem_resp_id), .inflight(r.inflight), .canceled(r.canceled),
    .miss_txv(r.miss_txv), .miss_txid(r.miss_txid), .state_swap_req(r.state == IC_SWAP_REQ),
    .req_accepted(mem_req_accepted), .req_accepted_id(mem_req_accepted_id),
    .active_resp(active_resp_unused), .drop_resp, .drop_mask
  );

  logic swap_in, ready_seen_now, accepted_now, already_inflight, waiting_accept, cw_accepted;

  always_comb begin
    swap_in          = r.state == IC_SWAP_REQ || r.state == IC_SWAP_WAIT;
    ready_seen_now   = r.state == IC_SWAP_REQ && mem_req_ready && r.miss_txv;
    accepted_now     = r.state == IC_SWAP_REQ && mem_req_accepted && mem_req_accepted_id == r.miss_txid && r.miss_txv;
    already_inflight = r.miss_txv && (r.state == IC_SWAP_WAIT || accepted_now);
    waiting_accept   = r.miss_txv && !already_inflight && (r.ready_seen || ready_seen_now);
    cw_accepted      = r.state == IC_CANCEL_WAIT && mem_req_accepted && r.miss_txv
                       && mem_req_accepted_id == r.miss_txid;
  end

  // DCache probe request of the SWAP_IN case (step_dcache_probe runs before the kill test there)
  always_comb begin
    dc_req_valid = swap_in && r.req_valid && !ic_is_uncache(r.ppn[IC_TAG_W-1 -: 2]) && !r.probe_done
                   && !r.probe_inflight;
    dc_req_addr  = ic_probe_addr(r.ppn, r.req_pc[11:IC_OFF_W], r.probe_word);
    mem_resp_ready = drop_resp || r.state == IC_CANCEL_WAIT;
  end

  logic [IC_TXID_N-1:0] txid_mask, set_both;

  always_comb begin
    txid_mask = ic_txid_onehot(r.miss_txid);
    set_both  = ((swap_in && already_inflight) || cw_accepted) ? txid_mask : '0;
    r_n = r;
    r_n.req_valid = 1'b0;
    r_n.ifu_ready = 1'b0;
    r_n.inflight  = (r.inflight & ~drop_mask) | set_both;
    r_n.canceled  = (r.canceled & ~drop_mask) | set_both;
    case (r.state)
      IC_SWAP_REQ, IC_SWAP_WAIT: begin
        r_n.state      = waiting_accept ? IC_CANCEL_WAIT : IC_IDLE;
        r_n.miss_txv   = waiting_accept ? r.miss_txv : 1'b0;
        r_n.ready_seen = waiting_accept ? (r.ready_seen || ready_seen_now) : 1'b0;
        r_n.probe_inflight = 1'b0;  r_n.probe_done = 1'b0;  r_n.probe_hit = 1'b0;  r_n.probe_word = '0;
      end
      IC_WAIT_DC, IC_CANCEL_WAIT: begin
        r_n.state      = IC_IDLE;
        r_n.miss_txv   = 1'b0;
        r_n.ready_seen = 1'b0;
        r_n.probe_inflight = 1'b0;  r_n.probe_done = 1'b0;  r_n.probe_hit = 1'b0;  r_n.probe_word = '0;
      end
      default: r_n.state = IC_IDLE;
    endcase
  end

endmodule

`default_nettype wire
