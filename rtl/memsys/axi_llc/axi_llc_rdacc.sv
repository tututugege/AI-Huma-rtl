`default_nettype none
// Ref: AXI_LLC.cpp  accept_new_requests (read part, 2699-2860) and drive_lookup_request, rr_read
// Read side of the lookup engine:
//   accept : one read request per tick (round-robin over the masters) when the lookup engine is free and nothing
//            conflicts: response slot busy, same line written / being written / victim in flight / refilled, a
//            second line fetch of a non-DCache master, no free MSHR
//   issue  : the lookup (launched earlier, not yet issued) reads the table row when no table write is in
//            progress and its line is neither a victim in flight nor being refilled
// All conflict checks look at the state at the END of the tick (the `_d` lists of the units).
module axi_llc_rdacc
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic [NR-1:0] rd_v,
  input  logic [NR-1:0] rd_byp,
  input  logic [NR-1:0][31:0] rd_addr,
  input  logic [NR-1:0][7:0] rd_size,
  input  logic [NR-1:0][3:0] rd_id,
  input  logic [NW-1:0] wr_v,
  input  logic [NW-1:0] wr_byp,
  input  logic [NW-1:0][31:0] wr_addr,
  input  logic [NR-1:0] slot_q,                // read response slot busy at the start / end of the tick
  input  logic [NR-1:0] slot_d,
  input  logic lookup_free,                    // lookup engine free after stage 3 and the write launch
  input  logic [NVL-1:0] vl_vld_d,
  input  logic [NVL-1:0][31:0] vl_addr_d,
  input  logic [NW*(WQD+1)-1:0] wl_vld_d,
  input  logic [NW*(WQD+1)-1:0][31:0] wl_line_d,
  input  logic [NMSHR-1:0] ml_vld_d,
  input  logic [NMSHR-1:0][31:0] ml_line_d,
  input  logic [NR-1:0] has_master_d,
  input  logic free_any_d,
  // table read issue
  input  logic lk_valid_q,
  input  logic lk_issued_q,
  input  addr_t lk_addr_q,
  input  logic tbl_busy,
  output logic issue,
  // accepted read
  output logic [NR-1:0] acc_grant,
  output logic [1:0] acc_master,
  output logic acc_any,
  output addr_t acc_addr,
  output logic [7:0] acc_size,
  output logic [3:0] acc_id,
  output logic acc_bypass
);
  logic [1:0] rr_q, rr_d;
  logic [NR-1:0] ok, vp_hit, wp_hit, mshr_hit, write_hit;
  logic lk_vp_hit, lk_mshr_hit;

  for (genvar r = 0; r < NR; r++) begin : g_cam
    axi_llc_linecam #(.N(NVL)) u_vp (.vld(vl_vld_d), .addr(vl_addr_d), .line(line_of(rd_addr[r])), .hit(vp_hit[r]));
    axi_llc_linecam #(.N(NW * (WQD + 1))) u_wp (.vld(wl_vld_d), .addr(wl_line_d), .line(line_of(rd_addr[r])),
                                                .hit(wp_hit[r]));
    axi_llc_linecam #(.N(NMSHR)) u_ms (.vld(ml_vld_d), .addr(ml_line_d), .line(line_of(rd_addr[r])),
                                       .hit(mshr_hit[r]));
  end

  // a write offered in this very tick to the same line also blocks the read
  always_comb begin
    for (int r = 0; r < NR; r++) begin
      write_hit[r] = 1'b0;
      for (int w = 0; w < NW; w++) write_hit[r] |= wr_v[w] && !wr_byp[w] && line_of(wr_addr[w]) == line_of(rd_addr[r]);
      // masters other than the DCache (1) fetch one line at a time
      ok[r] = rd_v[r] && !slot_q[r] && !slot_d[r] && lookup_free && !write_hit[r] && !wp_hit[r] && !vp_hit[r] &&
              !mshr_hit[r] && !(!rd_byp[r] && r != 1 && has_master_d[r]) && free_any_d;
    end
  end

  axi_llc_rrpick #(.N(NR)) u_pick (.req(ok), .ptr(rr_q), .grant(acc_grant), .idx(acc_master), .any(acc_any));

  always_comb begin
    rr_d = acc_any ? acc_master + 2'd1 : rr_q;
    acc_addr = '0;
    acc_size = '0;
    acc_id = '0;
    acc_bypass = 1'b0;
    for (int r = 0; r < NR; r++) begin
      acc_addr |= rd_addr[r] & {32{acc_grant[r]}};
      acc_size |= rd_size[r] & {8{acc_grant[r]}};
      acc_id |= rd_id[r] & {4{acc_grant[r]}};
      acc_bypass |= rd_byp[r] & acc_grant[r];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) rr_q <= '0;
    else        rr_q <= rr_d;
  end

  // table read issue (the lookup registers are those of the start of the tick)
  axi_llc_linecam #(.N(NVL)) u_lk_vp (.vld(vl_vld_d), .addr(vl_addr_d), .line(line_of(lk_addr_q)), .hit(lk_vp_hit));
  axi_llc_linecam #(.N(NMSHR)) u_lk_ms (.vld(ml_vld_d), .addr(ml_line_d), .line(line_of(lk_addr_q)),
                                        .hit(lk_mshr_hit));
  assign issue = lk_valid_q && !lk_issued_q && !lk_vp_hit && !tbl_busy && !lk_mshr_hit;
endmodule

`default_nettype wire
