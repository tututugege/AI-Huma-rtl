// Ref: front-end/icache/icache_module.cpp  ICache::eval_state_machine (canceled_resp / active_resp / orphan_resp)
`default_nettype none

// Classification of the AXI read response seen this cycle against the transaction bookkeeping of the I-cache.
// canceled: the response of a miss that was abandoned (refetch while the request was in flight)
// active:   the response of the miss being served (including the response that arrives in the cycle of the accept)
// orphan:   a response nobody is waiting for (its id is not in flight)
// canceled and orphan responses are simply accepted (mem_resp_ready) and their id released.
module icache_txn import icache_pkg::*; (
  input  logic                    resp_valid,
  input  logic [IC_TXID_W-1:0]    resp_id,
  input  logic [IC_TXID_N-1:0]    inflight,
  input  logic [IC_TXID_N-1:0]    canceled,
  input  logic                    miss_txv,
  input  logic [IC_TXID_W-1:0]    miss_txid,
  input  logic                    state_swap_req,       // SWAP_IN with the request not yet accepted (axi idle)
  input  logic                    req_accepted,
  input  logic [IC_TXID_W-1:0]    req_accepted_id,
  output logic                    active_resp,
  output logic                    drop_resp,            // canceled or orphan: accept it and free its id
  output logic [IC_TXID_N-1:0]    drop_mask             // one-hot of resp_id when drop_resp
);

  logic canceled_resp, resp_is_miss, resp_inflight, same_cycle_accept, orphan_resp;

  always_comb begin
    resp_is_miss      = resp_valid && miss_txv && resp_id == miss_txid;
    resp_inflight     = inflight[resp_id];
    canceled_resp     = resp_valid && canceled[resp_id];
    // the response may overtake the accept pulse: request accepted this very cycle with the same id
    same_cycle_accept = resp_is_miss && state_swap_req && req_accepted && req_accepted_id == miss_txid;
    active_resp       = resp_is_miss && (resp_inflight || same_cycle_accept) && !canceled_resp;
    orphan_resp       = resp_valid && !active_resp && !canceled_resp && !resp_inflight;
    drop_resp         = canceled_resp || orphan_resp;
    drop_mask         = drop_resp ? ic_txid_onehot(resp_id) : '0;
  end

endmodule

`default_nettype wire
