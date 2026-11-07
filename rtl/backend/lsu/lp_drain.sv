// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_lsu2dcache_stq_p: committed-store drain, MMIO store)
`default_nettype none

// Committed-store drain of the staged LSU: the NDR oldest ready stores (not MMIO) are candidates for the free store
// ports (a port with a pending DCache hidden retry is skipped; the m-th candidate uses the m-th free port).  A
// candidate
// is dropped for this cycle when an older committed, not done store overlaps its bytes (2 x 64 CAM: same word + byte
// strobe).  The head store, when it is MMIO, takes the uncached unit.
module lp_drain
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  lp_stq_t             sq [SQ],
  input  logic [SQ-1:0]       d_rdy,
  input  logic [SQ-1:0]       d_blk,
  input  logic [SQ-1:0]       d_elig,
  input  logic [SQW-1:0]      head_q,
  input  logic [NST-1:0]      retry_busy,
  input  logic                unc_busy,
  output logic [SQ-1:0]       dr_pick,
  output logic [SQ-1:0]       dr_mmio,
  output logic [NST-1:0]      req_valid,
  output logic [31:0]         req_addr [NST],
  output logic [31:0]         req_data [NST],
  output logic [4:0]          req_strb [NST],
  output logic [SQW-1:0]      req_id [NST],
  output logic                st_set,
  output logic [31:0]         st_addr,
  output logic [31:0]         st_wdata,
  output logic [2:0]          st_func3,
  output logic [SQW-1:0]      st_idx
);

  // ---- candidates: the NDR oldest ready non-MMIO stores ----
  logic [SQ-1:0] cand_vec, cand_rot;
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [SQ-1:0] c_oh [NDR];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [SQW-1:0] c_pos [NDR];
  logic [NDR-1:0] c_v;
  always_comb begin
    for (int j = 0; j < SQ; j++) cand_vec[j] = d_rdy[j] && !sq[j].mmio;
    cand_rot = SQ'(rotr64(64'(cand_vec), head_q));
  end
  lp_pickn #(.N(SQ), .K(NDR)) u_c (.vec(cand_rot), .onehot(c_oh), .idx(c_pos), .v(c_v));

  // ---- free ports: the m-th candidate takes the m-th port without a hidden retry ----
  logic [NDR-1:0] free_p;
  logic [NDR-1:0] f_oh [NDR];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [0:0]     f_ix [NDR];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NDR-1:0] f_v;
  always_comb begin
    for (int t = 0; t < NDR; t++) free_p[t] = !retry_busy[t];
  end
  lp_pickn #(.N(NDR), .K(NDR)) u_f (.vec(free_p), .onehot(f_oh), .idx(f_ix), .v(f_v));

  // ---- 2 x 64 overlap CAM ----
  logic [NDR-1:0] issue;
  logic [SQW-1:0] c_abs [NDR];
  always_comb begin
    for (int m = 0; m < NDR; m++) begin
      logic [SQ-1:0] older;
      logic [4:0]    sm;
      logic          hit;
      c_abs[m] = c_pos[m] + head_q;
      older = SQ'(rotl64(64'(~('1 << c_pos[m])), head_q));
      sm = lsu_pkg::store_strb(sq[c_abs[m]].paddr[1:0], sq[c_abs[m]].func3[1:0]);
      hit = 1'b0;
      for (int q = 0; q < SQ; q++) begin
        if (older[q] && d_blk[q] && sq[q].paddr[31:2] == sq[c_abs[m]].paddr[31:2] &&
            (lsu_pkg::store_strb(sq[q].paddr[1:0], sq[q].func3[1:0]) & sm) != 5'b0) hit = 1'b1;
      end
      issue[m] = c_v[m] && f_v[m] && !hit;
    end
  end

  always_comb begin
    dr_pick = '0;
    for (int m = 0; m < NDR; m++) if (issue[m]) dr_pick[c_abs[m]] = 1'b1;
  end

  // ---- request ports ----
  always_comb begin
    for (int t = 0; t < NST; t++) begin
      req_valid[t] = 1'b0;
      req_addr[t] = '0;
      req_data[t] = '0;
      req_strb[t] = '0;
      req_id[t] = '0;
      for (int m = 0; m < NDR; m++) begin
        if (t < NDR && issue[m] && f_oh[m][t]) begin
          req_valid[t] = 1'b1;
          req_addr[t] = sq[c_abs[m]].paddr;
          req_data[t] = lsu_pkg::align_store_data(sq[c_abs[m]].data, sq[c_abs[m]].paddr[1:0], sq[c_abs[m]].func3[1:0]);
          req_strb[t] = lsu_pkg::store_strb(sq[c_abs[m]].paddr[1:0], sq[c_abs[m]].func3[1:0]);
          req_id[t] = c_abs[m];
        end
      end
    end
  end

  // ---- MMIO store: only the head, uncached unit free ----
  always_comb begin
    dr_mmio = '0;
    st_set = d_elig[head_q] && sq[head_q].mmio && !unc_busy;
    dr_mmio[head_q] = st_set;
    st_addr = sq[head_q].paddr;
    st_wdata = sq[head_q].data;
    st_func3 = sq[head_q].func3;
    st_idx = head_q;
  end

endmodule

`default_nettype wire
