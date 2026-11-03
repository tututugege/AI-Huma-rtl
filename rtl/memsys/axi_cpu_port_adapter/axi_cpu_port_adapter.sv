// Ref: rv_simu_mmu_v2.cpp  capture_/accumulate_/restore_axi_cpu_boundary_state, mask_axi_cpu_boundary_for_internal_tick
`default_nettype none

// CPU-boundary adapter of the three non-DCache AXI master channels (spec/axi_cpu_port_adapter.io):
// channel 0 = ICache read master, 1 = peripheral read master, 2 = peripheral write master.  Runs on the fast clock;
// phase0 / phase_last mark tick 0 / tick 15 of the 16-tick CPU cycle.  The master side of the CPU (cpu_en) drives the
// ports only in tick 0 -- that masking lives with the masters, this block only folds the interconnect's answers.
module axi_cpu_port_adapter import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic phase0,
  input  logic phase_last,
  input  logic                 raw_ready        [AX_NCH],
  input  logic                 raw_accepted     [AX_NCH],
  input  logic [AX_ID_W-1:0]   raw_accepted_id  [AX_NCH],
  input  logic                 raw_resp_valid   [AX_NCH],
  input  logic [AX_ID_W-1:0]   raw_resp_id      [AX_NCH],
  input  logic                 raw_resp_ready   [AX_NCH],
  output logic                 cpu_ready        [AX_NCH],
  output logic                 cpu_accepted     [AX_NCH],
  output logic [AX_ID_W-1:0]   cpu_accepted_id  [AX_NCH],
  output logic                 cpu_resp_valid   [AX_NCH],
  output logic [AX_ID_W-1:0]   cpu_resp_id      [AX_NCH],
  output logic                 cpu_resp_ready   [AX_NCH]
);

  for (genvar c = 0; c < AX_NCH; c++) begin : g_chan
    axi_cpu_port_chan #(.EXPORT_ID(c != 2)) u_chan (
      .clk, .rst_n, .phase0, .phase_last,
      .raw_ready        (raw_ready[c]),
      .raw_accepted     (raw_accepted[c]),
      .raw_accepted_id  (raw_accepted_id[c]),
      .raw_resp_valid   (raw_resp_valid[c]),
      .raw_resp_id      (raw_resp_id[c]),
      .raw_resp_ready   (raw_resp_ready[c]),
      .cpu_ready        (cpu_ready[c]),
      .cpu_accepted     (cpu_accepted[c]),
      .cpu_accepted_id  (cpu_accepted_id[c]),
      .cpu_resp_valid   (cpu_resp_valid[c]),
      .cpu_resp_id      (cpu_resp_id[c]),
      .cpu_resp_ready   (cpu_resp_ready[c])
    );
  end

endmodule

`default_nettype wire
