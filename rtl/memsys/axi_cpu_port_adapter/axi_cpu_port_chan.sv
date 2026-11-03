// Ref: rv_simu_mmu_v2.cpp  capture/accumulate/restore_axi_cpu_boundary_state (per master channel)
`default_nettype none

// One non-DCache AXI master channel between the 16x faster interconnect domain and the CPU.  The CPU acts in tick 0
// of a 16-tick cycle; the interconnect advances every tick.  Over the 16 ticks of a cycle this block folds the
// interconnect's per-tick port values into the CPU view that is held for the whole NEXT cycle:
//   ready          : OR over all ticks
//   accepted / id  : sticky over all ticks, the id of the LAST accepted tick (observable only under accepted)
//   resp_valid / id: the response of the last tick, hidden when it belongs to the request accepted in this very cycle
//   resp_ready     : the master's tick-0 ready, withheld when the response is new in the extra ticks or hidden
// The view is registered at the end of tick 15 (phase_last).
module axi_cpu_port_chan import memcpu_pkg::*; #(
  parameter bit EXPORT_ID = 1'b1     // the write channel's accepted id is internal only
) (
  input  logic clk,
  input  logic rst_n,
  input  logic phase0,               // tick 0 of the cycle
  input  logic phase_last,           // tick 15
  input  logic                 raw_ready,
  input  logic                 raw_accepted,
  input  logic [AX_ID_W-1:0]   raw_accepted_id,
  input  logic                 raw_resp_valid,
  input  logic [AX_ID_W-1:0]   raw_resp_id,
  input  logic                 raw_resp_ready,
  output logic                 cpu_ready,
  output logic                 cpu_accepted,
  output logic [AX_ID_W-1:0]   cpu_accepted_id,
  output logic                 cpu_resp_valid,
  output logic [AX_ID_W-1:0]   cpu_resp_id,
  output logic                 cpu_resp_ready
);

  // ---- accumulation over the ticks of the cycle ----
  logic                 ready_acc_q, acc_q, resp0_valid_q, resp0_ready_q;
  logic [AX_ID_W-1:0]   acc_id_q, resp0_id_q;

  logic                 ready_acc_n, acc_n, resp0_valid_n, resp0_ready_n;
  logic [AX_ID_W-1:0]   acc_id_n, resp0_id_n;
  always_comb begin
    ready_acc_n   = phase0 ? raw_ready    : (ready_acc_q || raw_ready);
    acc_n         = phase0 ? raw_accepted : (acc_q || raw_accepted);
    acc_id_n      = raw_accepted ? raw_accepted_id : acc_id_q;   // id of the LAST accepted tick
    resp0_valid_n = phase0 ? raw_resp_valid : resp0_valid_q;
    resp0_id_n    = phase0 ? raw_resp_id    : resp0_id_q;
    resp0_ready_n = phase0 ? raw_resp_ready : resp0_ready_q;
  end

  // ---- the view of the finished cycle (only used on phase_last) ----
  // the answer of the request accepted in this very cycle is hidden
  wire hide_resp    = acc_n && raw_resp_valid && (raw_resp_id == acc_id_n);
  wire resp_is_new  = raw_resp_valid && !(resp0_valid_n && (resp0_id_n == raw_resp_id));
  logic view_resp_valid_n, view_resp_ready_n;
  always_comb begin
    view_resp_valid_n = raw_resp_valid && !hide_resp;
    view_resp_ready_n = resp0_ready_n && !(resp_is_new || hide_resp);
  end

  logic                 view_ready_q, view_accepted_q, view_resp_valid_q, view_resp_ready_q;
  logic [AX_ID_W-1:0]   view_accepted_id_q, view_resp_id_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ready_acc_q    <= 1'b0;
      acc_q          <= 1'b0;
      acc_id_q       <= '0;
      resp0_valid_q  <= 1'b0;
      resp0_id_q     <= '0;
      resp0_ready_q  <= 1'b0;
      view_ready_q       <= 1'b0;
      view_accepted_q    <= 1'b0;
      view_accepted_id_q <= '0;
      view_resp_valid_q  <= 1'b0;
      view_resp_id_q     <= '0;
      view_resp_ready_q  <= 1'b0;
    end else begin
      ready_acc_q    <= ready_acc_n;
      acc_q          <= acc_n;
      acc_id_q       <= acc_id_n;
      resp0_valid_q  <= resp0_valid_n;
      resp0_id_q     <= resp0_id_n;
      resp0_ready_q  <= resp0_ready_n;
      if (phase_last) begin
        view_ready_q       <= ready_acc_n;
        view_accepted_q    <= acc_n;
        view_accepted_id_q <= EXPORT_ID ? acc_id_n : '0;
        view_resp_valid_q  <= view_resp_valid_n;
        view_resp_id_q     <= raw_resp_id;
        view_resp_ready_q  <= view_resp_ready_n;
      end
    end
  end

  assign cpu_ready       = view_ready_q;
  assign cpu_accepted    = view_accepted_q;
  assign cpu_accepted_id = view_accepted_id_q;
  assign cpu_resp_valid  = view_resp_valid_q;
  assign cpu_resp_id     = view_resp_id_q;
  assign cpu_resp_ready  = view_resp_ready_q;

endmodule

`default_nettype wire
