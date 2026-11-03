// Ref: MemSubSystem/include/MemPtwBlock.h  WalkClientState, apply_port_inputs, send_walk_req, publish_*
`default_nettype none

// One walk client (a TLB).  A request is latched while the client has none pending / in flight; the walker grants it
// (pending -> inflight) and later publishes the result (inflight -> resp_valid).  The TLB sees only registered state:
// req_ready = no request pending/in flight, resp_valid and the response payload.
module ptw_walk_client import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  // TLB side
  input  logic                    req_valid,
  input  logic [PT_VPN_W-1:0]     req_vpn,
  input  logic [PT_PPN_IN_W-1:0]  req_root_ppn,
  input  logic                    resp_consumed,
  input  logic                    flush,
  output logic                    req_ready,
  output logic                    resp_valid,
  output logic                    resp_fault,
  output logic [PT_VPN_W-1:0]     resp_vpn,
  output logic [PT_PPN_W-1:0]     resp_leaf_ppn,
  output logic [PT_PERM_W-1:0]    resp_leaf_perm,
  output logic                    resp_leaf_level,
  // walker side
  output logic                    pending_a,        // pending after this cycle's latch (selection candidate)
  output logic [PT_VPN_W-1:0]     vpn_a,            // request after this cycle's latch
  output logic [PT_PPN_W-1:0]     root_ppn_a,
  input  logic                    sel,              // walker selects this client this cycle
  input  logic                    publish,          // walker publishes a result for this client this cycle
  input  logic                    pub_fault,
  input  logic [PT_PPN_W-1:0]     pub_ppn,
  input  logic [PT_PERM_W-1:0]    pub_perm,
  input  logic                    pub_level1
);

  /* verilator lint_off UNUSEDSIGNAL */  // root ppn bits [21:20] are shifted out of the 32-bit address
  wire [PT_PPN_IN_W-1:0] req_root_ppn_w = req_root_ppn;
  /* verilator lint_on UNUSEDSIGNAL */

  logic                 pending_q, inflight_q, resp_valid_q, fault_q, level_q;
  logic [PT_VPN_W-1:0]  vpn_q;
  logic [PT_PPN_W-1:0]  root_q, leaf_ppn_q;
  logic [PT_PERM_W-1:0] perm_q;

  // ---- request latch (send_walk_req): ignored while a request is pending / in flight ----
  wire busy_q = pending_q || inflight_q;
  wire latch  = req_valid && !busy_q;
  assign pending_a  = pending_q || latch;
  assign vpn_a      = latch ? req_vpn : vpn_q;
  assign root_ppn_a = latch ? req_root_ppn_w[PT_PPN_W-1:0] : root_q;

  // ---- next state; flush (applied at the clock edge on top of everything) wins ----
  // any request, valid or not, drops a stale response; a consumed response is dropped too
  wire resp_valid_a = resp_valid_q && !resp_consumed && !req_valid;
  logic pending_d, inflight_d, resp_valid_d;
  always_comb begin
    pending_d    = flush ? 1'b0 : (pending_a && !sel);
    inflight_d   = flush ? 1'b0 : ((inflight_q || sel) && !publish);
    resp_valid_d = flush ? 1'b0 : (publish || resp_valid_a);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending_q    <= 1'b0;
      inflight_q   <= 1'b0;
      resp_valid_q <= 1'b0;
    end else if (cpu_en) begin
      pending_q    <= pending_d;
      inflight_q   <= inflight_d;
      resp_valid_q <= resp_valid_d;
    end
  end

  // request and response payload registers (only meaningful under pending / resp_valid)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vpn_q      <= '0;
      root_q     <= '0;
      fault_q    <= 1'b0;
      leaf_ppn_q <= '0;
      perm_q     <= '0;
      level_q    <= 1'b0;
    end else if (cpu_en) begin
      if (latch) begin
        vpn_q  <= req_vpn;
        root_q <= req_root_ppn_w[PT_PPN_W-1:0];
      end
      if (publish) begin
        fault_q    <= pub_fault;
        leaf_ppn_q <= pub_fault ? '0 : pub_ppn;
        perm_q     <= pub_fault ? '0 : pub_perm;
        level_q    <= !pub_fault && pub_level1;
      end
    end
  end

  assign req_ready       = !busy_q;
  assign resp_valid      = resp_valid_q;
  assign resp_fault      = fault_q;
  assign resp_vpn        = vpn_q;
  assign resp_leaf_ppn   = leaf_ppn_q;
  assign resp_leaf_perm  = perm_q;
  assign resp_leaf_level = level_q;

endmodule

`default_nettype wire
