// Ref: front-end/icache/icache_module.cpp  ICache::eval_state_machine  case IDLE (fast bypass + registered
// request path)
`default_nettype none

// IDLE step (no kill).  A fetch whose translation is available in the cycle it is presented is answered at once
// (fast path: hit or page fault); otherwise the request is registered by icache_slot and answered from the register
// next cycle(s) (registered path).  A registered miss allocates an AXI transaction id and enters SWAP_IN.
module icache_idle import ttg_cfg_pkg::*; import icache_pkg::*; (
  input  ic_regs_t                r,
  input  logic                    req_valid_in,
  input  logic [XLEN_BITS-1:0]             pc,
  input  logic                    ppn_valid,
  input  logic                    page_fault,
  input  logic [IC_TAG_W-1:0]     ppn,
  input  logic                    hit,            // includes "translation valid and no fault"
  input  logic [IC_LINE_W-1:0]    hit_line,
  output ic_regs_t                r_n,            // only state/ppn/miss/probe fields change here
  output logic                    resp_valid,
  output logic [XLEN_BITS-1:0]             resp_pc,
  output logic                    resp_page_fault,
  output logic [IC_LINE_W-1:0]    resp_line,
  output logic                    req_ready,      // req_ready_w
  output logic                    fast_fire       // answered in the presentation cycle: slot stays empty
);

  logic fast, regp, answer, miss_reg, no_txid;
  logic [IC_TXID_N-1:0] free_onehot;
  logic [IC_TXID_W-1:0] free_id, alloc_id;
  logic                 free_any;

  ttg_first_set #(.N(IC_TXID_N)) u_free (.req(~r.inflight), .onehot(free_onehot), .any(free_any));
  ttg_onehot_to_idx #(.N(IC_TXID_N)) u_free_idx (.onehot(free_onehot), .idx(free_id));

  always_comb begin
    fast      = !r.req_valid && req_valid_in && ppn_valid;
    regp      = r.req_valid && ppn_valid;
    answer    = (fast || regp) && (page_fault || hit);
    miss_reg  = regp && !page_fault && !hit;
    alloc_id  = r.miss_txv ? r.miss_txid : free_id;
    no_txid   = !r.miss_txv && !free_any;
    resp_valid      = answer;
    resp_pc         = fast ? pc : r.req_pc;
    resp_page_fault = answer && page_fault;
    resp_line       = (answer && !page_fault) ? hit_line : '0;
    req_ready       = !r.req_valid || (ppn_valid && (page_fault || hit));
    fast_fire       = fast && answer;
  end

  always_comb begin
    r_n = r;
    if (regp && !page_fault) r_n.ppn = ppn;
    if (miss_reg && !no_txid) begin
      r_n.state      = IC_SWAP_REQ;
      r_n.miss_txv   = 1'b1;
      r_n.miss_txid  = alloc_id;
      r_n.ready_seen = 1'b0;
      r_n.probe_inflight = 1'b0;  r_n.probe_done = 1'b0;  r_n.probe_hit = 1'b0;  r_n.probe_word = '0;
    end
  end

endmodule

`default_nettype wire
