`default_nettype none
// Ref: AXI_LLC.cpp  pick_unreserved_way
// Way selection for a lookup miss: the first invalid way unless an in-flight refill / write-back owns it, otherwise
// the first unreserved way at or after the replacement pointer (cyclic).  ok = 0 when every way is reserved.
module axi_llc_waypick
  import axi_llc_pkg::*;
(
  input  logic inv_any,
  input  logic [WB-1:0] inv_way,
  input  logic [WAYS-1:0] reserved,
  input  logic [WB-1:0] repl,
  output logic ok,
  output logic [WB-1:0] way
);
  logic inv_ok, rr_any;
  logic [WB-1:0] rr_way;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [WAYS-1:0] rr_grant;                   // only the index of the grant is used
  /* verilator lint_on UNUSEDSIGNAL */

  axi_llc_rrpick #(.N(WAYS)) u_rr (.req(~reserved), .ptr(repl), .grant(rr_grant), .idx(rr_way), .any(rr_any));

  always_comb begin
    inv_ok = inv_any && !reserved[inv_way];
    ok = inv_ok || rr_any;
    way = inv_ok ? inv_way : rr_way;
  end
endmodule

`default_nettype wire
