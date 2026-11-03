// Ref: MemSubSystem/include/MemPtwBlock.h  MemPtwBlock (walk clients; comb_begin / comb_finish / seq)
`default_nettype none

// Page-table walker shared by the DTLB and the ITLB walk ports (spec/ptw_walk.io).
// Top level only adapts the flat spec ports.
module ptw_walk import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  input  logic                    client_req_valid     [PT_NCLIENT],
  input  logic [PT_VPN_W-1:0]     client_req_vpn       [PT_NCLIENT],
  input  logic [PT_PPN_IN_W-1:0]  client_req_root_ppn  [PT_NCLIENT],
  input  logic                    client_resp_consumed [PT_NCLIENT],
  input  logic                    client_flush         [PT_NCLIENT],
  input  logic                    grant_valid,
  input  logic [PT_ID_W-1:0]      grant_req_id,
  input  logic                    event_valid,
  input  logic [31:0]             event_data,
  input  logic [PT_ID_W-1:0]      event_req_id,
  input  logic                    wakeup_walk,
  output logic                    client_req_ready       [PT_NCLIENT],
  output logic                    client_resp_valid      [PT_NCLIENT],
  output logic                    client_resp_fault      [PT_NCLIENT],
  output logic [PT_VPN_W-1:0]     client_resp_vpn        [PT_NCLIENT],
  output logic [PT_PPN_W-1:0]     client_resp_leaf_ppn   [PT_NCLIENT],
  output logic [PT_PERM_W-1:0]    client_resp_leaf_perm  [PT_NCLIENT],
  output logic                    client_resp_leaf_level [PT_NCLIENT],
  output logic                    issue_walk_read,
  output logic [31:0]             walk_read_addr
);

  logic [PT_NCLIENT-1:0] pending_a, flush_v, sel, publish;
  logic [PT_VPN_W-1:0]   vpn_a  [PT_NCLIENT];
  logic [PT_PPN_W-1:0]   root_a [PT_NCLIENT];
  logic                  pub_fault, pub_level1;
  logic [PT_PPN_W-1:0]   pub_ppn;
  logic [PT_PERM_W-1:0]  pub_perm;

  for (genvar c = 0; c < PT_NCLIENT; c++) begin : g_client
    assign flush_v[c] = client_flush[c];
    ptw_walk_client u_client (
      .clk, .rst_n, .cpu_en,
      .req_valid       (client_req_valid[c]),
      .req_vpn         (client_req_vpn[c]),
      .req_root_ppn    (client_req_root_ppn[c]),
      .resp_consumed   (client_resp_consumed[c]),
      .flush           (client_flush[c]),
      .req_ready       (client_req_ready[c]),
      .resp_valid      (client_resp_valid[c]),
      .resp_fault      (client_resp_fault[c]),
      .resp_vpn        (client_resp_vpn[c]),
      .resp_leaf_ppn   (client_resp_leaf_ppn[c]),
      .resp_leaf_perm  (client_resp_leaf_perm[c]),
      .resp_leaf_level (client_resp_leaf_level[c]),
      .pending_a       (pending_a[c]),
      .vpn_a           (vpn_a[c]),
      .root_ppn_a      (root_a[c]),
      .sel             (sel[c]),
      .publish         (publish[c]),
      .pub_fault, .pub_ppn, .pub_perm, .pub_level1
    );
  end

  ptw_walk_engine u_engine (
    .clk, .rst_n, .cpu_en,
    .client_pending_a  (pending_a),
    .client_vpn_a      (vpn_a),
    .client_root_ppn_a (root_a),
    .client_flush      (flush_v),
    .client_sel        (sel),
    .client_publish    (publish),
    .pub_fault, .pub_ppn, .pub_perm, .pub_level1,
    .grant_valid, .grant_req_id, .event_valid, .event_data, .event_req_id, .wakeup_walk,
    .issue_walk_read, .walk_read_addr
  );

endmodule

`default_nettype wire
