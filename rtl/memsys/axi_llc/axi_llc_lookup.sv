`default_nettype none
// Ref: AXI_LLC.cpp  lookup_valid / lookup_issued / lookup_* registers  (try_launch_pending_write_lookup,
// accept_new_requests, drive_lookup_request)
// The lookup engine: one request (read or write) at a time.  It is launched (valid, not issued), its table read is
// issued one tick later (issued), the row arrives three ticks after that and stage 3 resolves it: done (valid
// drops) or retry (issued drops, the table read is issued again).
module axi_llc_lookup
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic done,                           // stage 3 resolved the lookup
  input  logic retry,                          // stage 3 could not: issue the table read again
  input  logic issue,                          // table read issued in this tick
  input  logic w_launch,                       // a write context starts its lookup
  input  addr_t w_addr,
  input  logic [7:0] w_size,
  input  logic [3:0] w_id,
  input  logic [1:0] w_master,
  input  logic w_bypass,
  input  logic r_launch,                       // a read request is accepted
  input  addr_t r_addr,
  input  logic [7:0] r_size,
  input  logic [3:0] r_id,
  input  logic [1:0] r_master,
  input  logic r_bypass,
  output logic valid_q,
  output logic issued_q,
  output logic is_write_q,
  output logic bypass_q,
  output addr_t addr_q,
  output logic [7:0] size_q,
  output logic [1:0] master_q,
  output logic [3:0] id_q,
  output logic free_s3                         // no lookup in flight after stage 3 (a new one may start)
);
  logic valid_d, issued_d, is_write_d, bypass_d, new_lookup;

  always_comb begin
    free_s3 = !valid_q || done;
    new_lookup = w_launch || r_launch;
    valid_d = (valid_q && !done) || new_lookup;
    issued_d = (issued_q && !retry && !done) || issue;
    is_write_d = (is_write_q && !done) || w_launch;
    bypass_d = (bypass_q && !done) || (r_launch && r_bypass) || (w_launch && w_bypass);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      issued_q <= 1'b0;
      is_write_q <= 1'b0;
      bypass_q <= 1'b0;
    end else begin
      valid_q <= valid_d;
      issued_q <= issued_d;
      is_write_q <= is_write_d;
      bypass_q <= bypass_d;
    end
  end

  always_ff @(posedge clk) begin
    if (w_launch) begin
      addr_q <= w_addr;
      size_q <= w_size;
      master_q <= w_master;
      id_q <= w_id;
    end else if (r_launch) begin
      addr_q <= r_addr;
      size_q <= r_size;
      master_q <= r_master;
      id_q <= r_id;
    end
  end
endmodule

`default_nettype wire
