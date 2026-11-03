`default_nettype none
// Ref: AXI_Interconnect.cpp  comb_read_arbiter (LLC mem read issue), comb_read_response, seq (AR / R channels),
//   prepare_llc_inputs
// DDR read side: the LLC's memory read request becomes an AXI AR (latched until arready); in-flight reads are
//   tracked in
// r_pend[mem id] (the C++ vector is order-independent: at most one entry is complete at any time); R beats fill
//   the entry; the
// first complete entry is presented to the LLC (small reads shifted back out of their 32-byte beat) and released
//   when presented.
module axi_ic_ar
  import axi_ic_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  // LLC memory read request
  input  logic          lo_valid,
  input  logic [31:0]   lo_addr,
  input  logic [7:0]    lo_size,
  input  logic [3:0]    lo_id,
  // pending DDR writes (hazard against a new AR)
  input  logic          wp_v    [2],
  input  logic [25:0]   wp_line [2],
  // DDR read channels
  input  logic          d_arready,
  input  logic          d_rvalid,
  input  logic [5:0]    d_rid,
  input  logic [255:0]  d_rdata,
  output logic          o_arvalid,
  output logic [5:0]    o_arid,
  output logic [31:0]   o_araddr,
  output logic          o_arlen,
  // to the LLC
  output logic          li_rd_ready,
  output logic          li_resp_valid,
  output logic [511:0]  li_resp_data,
  output logic [3:0]    li_resp_id,
  // pending-read views for the hazard checks
  output logic [NM-1:0] rp_v,            // r_pend slot valid
  output logic [NM:0]   pr_v,            // AR latch + r_pend not yet complete
  output logic [25:0]   pr_line [NM+1],
  output logic          fr_v,            // AR issued fresh this tick (has_external_pending_read_hazard only)
  output logic [25:0]   fr_line
);
  typedef struct packed {
    logic v;
    logic [31:0] addr;       // issue address
    logic        len;
    logic [5:0]  id;
    logic [3:0]  orig;
    logic [31:0] upaddr;
    logic        ext;
  } latch_t;
  typedef struct packed {
    logic v;
    logic [5:0] id;
    logic tot2;              // 2 beats (else 1)
    logic [1:0] done;
    logic [4:0] off;
    logic ext;
    logic [31:0] upaddr;
    logic [511:0] data;
  } pend_t;

  latch_t latch_q, latch_d;
  pend_t  pend_q [NM];
  pend_t  pend_d [NM];
  logic        seen_v_q, seen_v_d;
  logic [3:0]  seen_id_q;
  logic [31:0] seen_addr_q;
  logic [7:0]  seen_size_q;

  // ---------------- AXI id allocation: lowest id not used by r_pend / the latch ----------------
  logic [15:0] used;
  logic [15:0] free_oh;
  logic        free_any;
  logic [3:0]  free_id;
  always_comb begin
    used = '0;
    for (int s = 0; s < NM; s++) if (pend_q[s].v) used[pend_q[s].id[3:0]] = 1'b1;
    if (latch_q.v) used[latch_q.id[3:0]] = 1'b1;
  end
  ttg_first_set #(.N(16)) u_free (.req(~used), .onehot(free_oh), .any(free_any));
  ttg_onehot_to_idx #(.N(16)) u_free_idx (.onehot(free_oh), .idx(free_id));

  // ---------------- hazards: pending DDR writes of the same 64-byte line block a new read ----------------
  logic wr_haz;
  assign wr_haz = (wp_v[0] && wp_line[0] == line64(lo_addr)) || (wp_v[1] && wp_line[1] == line64(lo_addr));

  logic seen_match, fresh;
  assign seen_match = seen_v_q && seen_id_q == lo_id && seen_addr_q == lo_addr && seen_size_q == lo_size;
  assign fresh = lo_valid && !seen_match && !latch_q.v && !wr_haz;
  assign li_rd_ready = !latch_q.v && (!lo_valid || !wr_haz);

  // AR channel
  assign o_arvalid = latch_q.v || fresh;
  assign o_arid    = latch_q.v ? latch_q.id   : {2'b0, free_id};
  assign o_araddr  = latch_q.v ? latch_q.addr : issue_addr(lo_addr, lo_size);
  assign o_arlen   = latch_q.v ? latch_q.len  : issue_len(lo_size);
  assign fr_v      = fresh;
  assign fr_line   = line64(lo_addr);

  // ---------------- views ----------------
  for (genvar s = 0; s < NM; s++) begin : g_v
    assign rp_v[s] = pend_q[s].v;
    assign pr_v[s] = pend_q[s].v && (pend_q[s].done != (pend_q[s].tot2 ? 2'd2 : 2'd1));
    assign pr_line[s] = line64(pend_q[s].upaddr);
  end
  assign pr_v[NM]    = latch_q.v;
  assign pr_line[NM] = line64(latch_q.upaddr);

  // ---------------- next state ----------------
  logic ar_fire;
  assign ar_fire = o_arvalid && d_arready;

  pend_t pend_p [NM];       // after the AR push
  logic [MW-1:0] push_idx;
  always_comb begin
    push_idx = latch_q.v ? latch_q.orig[MW-1:0] : lo_id[MW-1:0];
    for (int s = 0; s < NM; s++) pend_p[s] = pend_q[s];
    if (ar_fire) begin
      pend_p[push_idx] = '{v: 1'b1, id: o_arid, tot2: o_arlen, done: 2'd0,
                                   off: (latch_q.v ? latch_q.upaddr[4:0] : lo_addr[4:0]),
                                   ext: (latch_q.v ? latch_q.ext : issue_small(lo_size)),
                                   upaddr: (latch_q.v ? latch_q.upaddr : lo_addr), data: '0};
    end
  end

  // presented complete entry (first by slot index; at most one exists) and its release
  logic [NM-1:0] comp, comp_oh;
  logic          comp_any;
  logic [MW-1:0] comp_idx;
  always_comb begin
    for (int s = 0; s < NM; s++) comp[s] = pend_q[s].v && (pend_q[s].done == (pend_q[s].tot2 ? 2'd2 : 2'd1));
  end
  ttg_first_set #(.N(NM)) u_comp (.req(comp), .onehot(comp_oh), .any(comp_any));
  ttg_onehot_to_idx #(.N(NM)) u_comp_idx (.onehot(comp_oh), .idx(comp_idx));
  assign li_resp_valid = comp_any;
  assign li_resp_id    = 4'(comp_idx);
  assign li_resp_data  = pend_q[comp_idx].ext ? (pend_q[comp_idx].data >> {pend_q[comp_idx].off, 3'b000})
                                              : pend_q[comp_idx].data;

  always_comb begin
    for (int s = 0; s < NM; s++) begin
      pend_d[s] = pend_p[s];
      // R beat: entry whose axi id matches and that still needs beats (looked up in the post-push table)
      if (d_rvalid && pend_p[s].v && pend_p[s].id == d_rid && pend_p[s].done != (pend_p[s].tot2 ? 2'd2 : 2'd1)) begin
        if (pend_p[s].done[0]) pend_d[s].data[511:256] = d_rdata;
        else                   pend_d[s].data[255:0]   = d_rdata;
        pend_d[s].done = pend_p[s].done + 2'd1;
      end
      if (comp_oh[s]) pend_d[s] = '0;      // handed to the LLC (read_resp_ready is constant 1)
    end
  end

  always_comb begin
    latch_d = latch_q;
    if (ar_fire) latch_d.v = 1'b0;
    else if (fresh && !d_arready)
      latch_d = '{v: 1'b1, addr: o_araddr, len: o_arlen, id: o_arid, orig: lo_id, upaddr: lo_addr,
                  ext: issue_small(lo_size)};
    seen_v_d = fresh ? 1'b1 : (lo_valid ? seen_v_q : 1'b0);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      latch_q <= '0;
      for (int s = 0; s < NM; s++) pend_q[s] <= '0;
      seen_v_q <= 1'b0; seen_id_q <= '0; seen_addr_q <= '0; seen_size_q <= '0;
    end else begin
      latch_q <= latch_d;
      for (int s = 0; s < NM; s++) pend_q[s] <= pend_d[s];
      seen_v_q <= seen_v_d;
      if (fresh) begin seen_id_q <= lo_id; seen_addr_q <= lo_addr; seen_size_q <= lo_size; end
    end
  end

`ifndef SYNTHESIS
  // C++ keeps a vector (two entries with one LLC mem id would be possible); the indexed table cannot, and ids >= 16
  //   cannot occur.
  assert property (@(posedge clk) disable iff (!rst_n)
                   !(ar_fire && pend_q[push_idx].v && !comp_oh[push_idx]))
    else $error("axi_ic_ar: second outstanding read with the same LLC mem id");
  assert property (@(posedge clk) disable iff (!rst_n) !(fresh && !free_any))
    else $error("axi_ic_ar: no free AXI id below 16");
`endif
endmodule

`default_nettype wire
