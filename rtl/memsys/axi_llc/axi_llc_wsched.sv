`default_nettype none
// Ref: AXI_LLC.cpp  drive_write_path (accept + context fill) and try_launch_pending_write_lookup, rr_write
// Write-side arbitration with one round-robin pointer shared by accept and lookup launch:
//   accept : one write request per tick, first master from the pointer whose queue has room and whose line is not
//            a victim in flight (only while the write path is not blocked by a victim write-back)
//   launch : the first write context from the (accept-updated) pointer that waits for the lookup engine
// Bypass writes are issued to memory by the same round-robin pointer (first context from the start-of-tick
// pointer that was not issued yet) while the write path is not blocked by a victim write-back.
// It also answers the victim hazard of the queue fronts that move into the contexts.
module axi_llc_wsched
  import axi_llc_pkg::*;
#(
  parameter int PW = $clog2(NW)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [NW-1:0] wr_v,
  input  logic [NW-1:0][31:0] wr_addr,
  input  logic [NW-1:0] wq_free,
  input  logic path_en,
  input  logic [NVL-1:0] vl_vld_cur,             // victim-holder list, state at the start of the tick
  input  logic [NVL-1:0][31:0] vl_addr_cur,
  input  logic [NW-1:0][31:0] head_addr,       // queue fronts
  input  logic [NW+NMSHR-1:0] fl_vld,          // victim holders that can still be pending when a front moves in
  input  logic [NW+NMSHR-1:0][31:0] fl_addr,
  input  logic [NW-1:0] launch_cand,
  input  logic [NW-1:0] bp_cand,
  input  logic lookup_free,
  output logic [NW-1:0] acc_grant,
  output logic [NW-1:0] fill_blocked,
  output logic [NW-1:0] bp_grant,
  output logic [NW-1:0] launch_grant,
  output logic launch_any,
  output logic [PW-1:0] launch_idx
);
  logic [PW-1:0] rr_q, rr_acc, rr_d;
  logic [NW-1:0] acc_cand, victim_hit_q;
  logic [PW-1:0] acc_idx;
  logic acc_any;
  /* verilator lint_off UNUSEDSIGNAL */
  logic bp_any;                                // only the grant of the bypass pick is used
  logic [PW-1:0] bp_idx;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NW-1:0] bp_pick;

  for (genvar w = 0; w < NW; w++) begin : g_cam
    axi_llc_linecam #(.N(NVL)) u_acc (.vld(vl_vld_cur), .addr(vl_addr_cur), .line(line_of(wr_addr[w])),
                                      .hit(victim_hit_q[w]));
    axi_llc_linecam #(.N(NW + NMSHR)) u_fill (.vld(fl_vld), .addr(fl_addr), .line(line_of(head_addr[w])),
                                              .hit(fill_blocked[w]));
  end

  always_comb begin
    acc_cand = wr_v & wq_free & ~victim_hit_q & {NW{path_en}};
    rr_acc = acc_any ? acc_idx + PW'(1) : rr_q;
    rr_d = launch_any ? launch_idx + PW'(1) : rr_acc;
  end

  axi_llc_rrpick #(.N(NW)) u_acc_pick (.req(acc_cand), .ptr(rr_q), .grant(acc_grant), .idx(acc_idx), .any(acc_any));
  axi_llc_rrpick #(.N(NW)) u_bp_pick (.req(bp_cand), .ptr(rr_q), .grant(bp_pick), .idx(bp_idx), .any(bp_any));
  assign bp_grant = bp_pick & {NW{path_en}};
  axi_llc_rrpick #(.N(NW)) u_launch_pick (.req(launch_cand & {NW{lookup_free}}), .ptr(rr_acc), .grant(launch_grant),
                                          .idx(launch_idx), .any(launch_any));

  always_ff @(posedge clk) begin
    if (!rst_n) rr_q <= '0;
    else        rr_q <= rr_d;
  end
endmodule

`default_nettype wire
