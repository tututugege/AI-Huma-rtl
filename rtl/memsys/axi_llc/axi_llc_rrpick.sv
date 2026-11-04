`default_nettype none
// Ref: AXI_LLC.cpp  round-robin master / way scans (`for off in 0..N-1: idx = (ptr + off) % N`, first hit wins)
// Rotating-priority arbiter: the first requester at or after `ptr` (cyclically) is granted.  N is a power of two.
module axi_llc_rrpick #(
  parameter int N  = 4,
  parameter int PW = (N > 1) ? $clog2(N) : 1
) (
  input  logic [N-1:0]  req,
  input  logic [PW-1:0] ptr,
  output logic [N-1:0]  grant,
  output logic [PW-1:0] idx,
  output logic          any
);
  logic [N-1:0]   rot_req;
  logic [N-1:0]   rot_grant;
  logic [2*N-1:0] doubled_req;
  logic [2*N-1:0] doubled_grant;
  int unsigned    left_amount;

  // rotate right by ptr: bit i of rot_req is req[(i + ptr) % N]
  always_comb begin
    doubled_req = {req, req};
    rot_req = N'(doubled_req >> ptr);
  end

  ttg_first_set #(.N(N)) u_first (.req(rot_req), .onehot(rot_grant), .any(any));

  // rotate left by ptr: bit j of grant is rot_grant[(j - ptr) % N]
  always_comb begin
    doubled_grant = {rot_grant, rot_grant};
    left_amount = 32'(N) - 32'(ptr);
    grant = N'(doubled_grant >> left_amount);
  end

  ttg_onehot_to_idx #(.N(N), .IDXW(PW)) u_idx (.onehot(grant), .idx(idx));
endmodule

`default_nettype wire
