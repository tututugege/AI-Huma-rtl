`default_nettype none
// Ref: AXI_LLC.cpp  victim_wb (global victim write-back slot) + read_victim_wb_q  (drive_write_path, 1486-1640)
// Victim write-back unit.  `vwb` is the one write-back in flight towards memory; the read-victim queue (rvq) parks
// dirty victims of read refills behind it.  A victim comes from one of three places:
//   forw  : a write miss evicts a dirty line; the write context waits (cpend) until the response arrives
//   queue : the head of the rvq (stays in the queue until the response pops it)
//   owner : a refill parks the snapshot of its MSHR in an idle slot (own_*); otherwise it is queued
// While vwb is busy the write path accepts nothing (busy_s2).
// Quirk kept from the C++: after a queue victim's response pops the head, the "load next victim" step still sees
// the old head and re-issues the same line once more.
module axi_llc_victim
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic mwr_resp_v,
  input  logic mwr_ready,
  // stage 3: write miss with a dirty victim
  input  logic forw_go,
  input  logic forw_wm,
  input  addr_t forw_addr,
  input  line_t forw_data,
  // stage 4: refill parks the dirty snapshot of its MSHR; owner slot released when the refill completes
  input  logic park_go,
  input  logic [MIDW-1:0] park_own,
  input  addr_t park_addr,
  input  line_t park_data,
  input  logic own_clr,
  input  logic bp_owner_any,                   // a bypass write is outstanding: no victim is loaded or issued
  input  logic [MIDW-1:0] own_clr_id,
  // memory write channel
  output logic mwr_v,
  output addr_t mwr_addr,
  output line_t mwr_data,
  // victim write response for a write context
  output logic resp_forw,
  output logic resp_wm,
  output logic busy_s2,                        // write-back slot occupied after response / queue load
  output logic busy_s3,                        // ... and after a stage-3 load
  output logic rvq_full_s2,
  // victim-holder lists: slot 0 = write-back slot, 1..VQD = queue entries
  output logic [VQD:0] vl_vld_cur,
  output logic [VQD:0][31:0] vl_addr_cur,
  output logic [VQD:0] vl_vld_d,
  output logic [VQD:0][31:0] vl_addr_d,
  output logic [VQD:0] pr_vld_s2,              // snapshots (non-forw) present after stage 2
  output logic [VQD:0][31:0] pr_addr_s2,
  output logic bp_resp,                        // memory write response that is not the write-back's (bypass write)
  output logic own_resp,                       // response of a write-back owned by an MSHR slot ...
  output logic [MIDW-1:0] own_idx,
  output addr_t own_addr
);
  // ---------------- write-back slot ----------------
  logic vw_valid_q, vw_issued_q, vw_forw_q, vw_wm_q, vw_ownv_q;
  logic [MIDW-1:0] vw_own_q;
  addr_t vw_addr_q;
  line_t vw_data_q;
  // ---------------- read-victim queue ----------------
  logic [VQD-1:0] rv_vld_q, rv_vld_d, rv_vld_s2;
  logic [VQW-1:0] rv_head_q, rv_tail_q;
  addr_t rv_addr_q [VQD];
  line_t rv_data_q [VQD];

  logic resp, valid_r, load, head_match, pop, park_vwb, push, load_or_new;
  logic vw_valid_d, vw_issued_d, vw_forw_d, vw_ownv_d, own_clr_here;
  addr_t head_addr, vw_addr_d;
  line_t head_data;

  always_comb begin
    head_addr = rv_addr_q[rv_head_q];
    head_data = rv_data_q[rv_head_q];
    resp = mwr_resp_v && vw_valid_q && vw_issued_q;
    bp_resp = mwr_resp_v && !(vw_valid_q && vw_issued_q);
    resp_forw = resp && vw_forw_q;
    resp_wm = vw_wm_q;
    own_resp = resp && !vw_forw_q && vw_ownv_q;
    own_idx = vw_own_q;
    own_addr = vw_addr_q;
    head_match = rv_vld_q[rv_head_q] && head_addr == vw_addr_q;
    pop = resp && !vw_forw_q && !vw_ownv_q && head_match;
    rv_vld_s2 = rv_vld_q;
    if (pop) rv_vld_s2[rv_head_q] = 1'b0;
    rvq_full_s2 = &rv_vld_s2;
    valid_r = vw_valid_q && !resp;
    // reads the queue head of the OLD state (duplicate re-issue); nothing is loaded while a bypass write is out
    load = !valid_r && rv_vld_q[rv_head_q] && !bp_owner_any;
    busy_s2 = valid_r || load;
  end

  always_comb begin
    busy_s3 = busy_s2 || forw_go;
  end

  // a refill parks its victim snapshot: idle slot, else the queue
  always_comb begin
    park_vwb = park_go && !busy_s3;
    push = park_go && busy_s3;
    load_or_new = load || forw_go || park_vwb;
  end

  // memory write request: a freshly loaded victim is issued in the same tick
  always_comb begin
    mwr_v = load || (valid_r && !vw_issued_q && !bp_owner_any);
    mwr_addr = load ? head_addr : vw_addr_q;
    mwr_data = load ? head_data : vw_data_q;
  end

  // next state of the write-back slot
  always_comb begin
    own_clr_here = own_clr && valid_r && vw_ownv_q && vw_own_q == own_clr_id;
    vw_valid_d = busy_s3 || park_vwb;
    vw_issued_d = !(forw_go || park_vwb) && ((valid_r && vw_issued_q) || (mwr_v && mwr_ready));
    vw_forw_d = forw_go || (vw_forw_q && !load && !park_vwb);
    vw_ownv_d = park_vwb || (vw_ownv_q && !own_clr_here && !load && !forw_go);
    vw_addr_d = forw_go ? forw_addr : park_vwb ? park_addr : load ? head_addr : vw_addr_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vw_valid_q <= 1'b0;
      vw_issued_q <= 1'b0;
      vw_forw_q <= 1'b0;
      vw_ownv_q <= 1'b0;
    end else begin
      vw_valid_q <= vw_valid_d;
      vw_issued_q <= vw_issued_d;
      vw_forw_q <= vw_forw_d;
      vw_ownv_q <= vw_ownv_d;
    end
  end

  always_ff @(posedge clk) begin
    if (load_or_new) begin
      vw_addr_q <= vw_addr_d;
      vw_data_q <= forw_go ? forw_data : park_vwb ? park_data : head_data;
    end
    if (forw_go) vw_wm_q <= forw_wm;
    if (park_vwb) vw_own_q <= park_own;
  end

  // read-victim queue: valid bit per entry, storage written at the tail, read at the head
  always_comb begin
    rv_vld_d = rv_vld_s2;
    if (push) rv_vld_d[rv_tail_q] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rv_vld_q <= '0;
      rv_head_q <= '0;
      rv_tail_q <= '0;
    end else begin
      rv_vld_q <= rv_vld_d;
      rv_head_q <= rv_head_q + VQW'(pop);
      rv_tail_q <= rv_tail_q + VQW'(push);
    end
  end
  for (genvar i = 0; i < VQD; i++) begin : g_rv
    always_ff @(posedge clk) begin
      if (push && rv_tail_q == VQW'(i)) begin
        rv_addr_q[i] <= park_addr;
        rv_data_q[i] <= park_data;
      end
    end
  end

  // lists for the line-address hazard checks
  always_comb begin
    vl_vld_cur[0] = vw_valid_q;
    vl_addr_cur[0] = vw_addr_q;
    vl_vld_d[0] = vw_valid_d;
    vl_addr_d[0] = vw_addr_d;
    pr_vld_s2[0] = busy_s2 && !(valid_r && vw_forw_q);
    pr_addr_s2[0] = load ? head_addr : vw_addr_q;
    for (int i = 0; i < VQD; i++) begin
      vl_vld_cur[1 + i] = rv_vld_q[i];
      vl_addr_cur[1 + i] = rv_addr_q[i];
      vl_vld_d[1 + i] = rv_vld_d[i];
      vl_addr_d[1 + i] = (push && rv_tail_q == VQW'(i)) ? park_addr : rv_addr_q[i];
      pr_vld_s2[1 + i] = rv_vld_s2[i];
      pr_addr_s2[1 + i] = rv_addr_q[i];
    end
  end

`ifndef SYNTHESIS
  // the C++ queue is 32 deep; the RTL depth is never reached in any measured run
  assert property (@(posedge clk) disable iff (!rst_n) !(&rv_vld_d))
    else $error("axi_llc_victim: victim queue full");
`endif
endmodule

`default_nettype wire
