// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_lsu2dcache_stq_p: committed-store drain, MMIO store)
`default_nettype none

// Committed-store drain of the staged LSU: the NDC oldest ready stores (not MMIO) are candidates for the NDR store
// ports.  Store merging (EXP-024, model LSU_PIPE_MERGE=2 / MGRAN=16): an unblocked candidate that
// lies in the same 16-byte granule as an earlier candidate that took a port (a leader without a follower yet) does not
// take a port: it rides on the request of that leader as its second word (req_l2) and completes with the leader's
// response.  The first leader in candidate order wins.  A candidate is dropped for this cycle when an older
// committed, not done store overlaps its bytes (NDC x 64 CAM: same word + byte strobe); a dropped candidate does not
// take a port.  The m-th remaining leader candidate uses the m-th port without a pending DCache hidden retry
// (candidates beyond the free ports wait).  The head store, when it is MMIO, takes the uncached unit.
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
  output logic [SQ-1:0]       dr_pick,         // leaders and followers
  output logic [SQ-1:0]       dr_fol,          // followers
  output logic [SQW-1:0]      dr_ml [SQ],      // leader of a follower
  output logic [SQ-1:0]       dr_mmio,
  output logic [NST-1:0]      req_valid,
  output logic [31:0]         req_addr [NST],
  output logic [31:0]         req_data [NST],
  output logic [4:0]          req_strb [NST],
  output logic [39:0]         req_l2 [NST],
  output logic [SQW-1:0]      req_id [NST],
  output logic                st_set,
  output logic [31:0]         st_addr,
  output logic [31:0]         st_wdata,
  output logic [2:0]          st_func3,
  output logic [SQW-1:0]      st_idx
);

  // ---- candidates: the NDC oldest ready non-MMIO stores ----
  logic [SQ-1:0] cand_vec, cand_rot;
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [SQ-1:0] c_oh [NDC];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [SQW-1:0] c_pos [NDC];
  logic [NDC-1:0] c_v;
  always_comb begin
    for (int j = 0; j < SQ; j++) cand_vec[j] = d_rdy[j] && !sq[j].mmio;
    cand_rot = SQ'(rotr64(64'(cand_vec), head_q));
  end
  lp_pickn #(.N(SQ), .K(NDC)) u_c (.vec(cand_rot), .onehot(c_oh), .idx(c_pos), .v(c_v));

  // ---- free ports: the m-th unblocked candidate takes the m-th port without a hidden retry ----
  logic [NDR-1:0] free_p;
  logic [NDR-1:0] f_oh [NDR];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]     f_ix [NDR];
  logic [NDR-1:0] f_v;  // validity is carried by f_oh (all zero when the port does not exist)
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    for (int t = 0; t < NDR; t++) free_p[t] = !retry_busy[t];
  end
  lp_pickn #(.N(NDR), .K(NDR), .IW(2)) u_f (.vec(free_p), .onehot(f_oh), .idx(f_ix), .v(f_v));

  // ---- NDC x 64 overlap CAM; a blocked candidate does not take a port ----
  logic [NDC-1:0] ok, lead, fol;
  logic [SQW-1:0] c_abs [NDC];
  logic [NDR-1:0] c_port [NDC];    // port of leader m (one-hot)
  logic [NDC-1:0] fl [NDC];        // fl[m]: the leader of follower m (one-hot over the candidates)
  logic [27:0]    gran [NDC];
  always_comb begin
    for (int m = 0; m < NDC; m++) begin
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
      ok[m] = c_v[m] && !hit;
      gran[m] = sq[c_abs[m]].paddr[31:4];
    end
    begin
      logic [NDC-1:0] has_fol;
      int             cnt;
      has_fol = '0;
      cnt = 0;
      for (int m = 0; m < NDC; m++) begin
        logic found;
        found = 1'b0;
        fl[m] = '0;
        c_port[m] = '0;
        lead[m] = 1'b0;
        fol[m] = 1'b0;
        for (int l = 0; l < m; l++) begin
          if (ok[m] && !found && lead[l] && !has_fol[l] && gran[l] == gran[m]) begin
            found = 1'b1;
            fl[m][l] = 1'b1;
            has_fol[l] = 1'b1;
          end
        end
        fol[m] = found;
        if (ok[m] && !found) begin
          if (cnt < NDR) begin
            for (int r = 0; r < NDR; r++) if (cnt == r) c_port[m] = f_oh[r];
            lead[m] = c_port[m] != '0;
            cnt = cnt + 1;
          end
        end
      end
    end
  end

  always_comb begin
    dr_pick = '0;
    dr_fol = '0;
    for (int j = 0; j < SQ; j++) dr_ml[j] = '0;
    for (int m = 0; m < NDC; m++) begin
      if (lead[m] || fol[m]) dr_pick[c_abs[m]] = 1'b1;
      if (fol[m]) begin
        dr_fol[c_abs[m]] = 1'b1;
        for (int l = 0; l < m; l++) if (fl[m][l]) dr_ml[c_abs[m]] = c_abs[l];
      end
    end
  end

  // ---- request ports ----
  always_comb begin
    for (int t = 0; t < NST; t++) begin
      req_valid[t] = 1'b0;
      req_addr[t] = '0;
      req_data[t] = '0;
      req_strb[t] = '0;
      req_id[t] = '0;
      req_l2[t] = '0;
      for (int m = 0; m < NDC; m++) begin
        if (t < NDR && lead[m] && c_port[m][t]) begin
          req_valid[t] = 1'b1;
          req_addr[t] = sq[c_abs[m]].paddr;
          req_data[t] = lsu_pkg::align_store_data(sq[c_abs[m]].data, sq[c_abs[m]].paddr[1:0], sq[c_abs[m]].func3[1:0]);
          req_strb[t] = lsu_pkg::store_strb(sq[c_abs[m]].paddr[1:0], sq[c_abs[m]].func3[1:0]);
          req_id[t] = c_abs[m];
          for (int f = 0; f < NDC; f++) begin
            if (fol[f] && fl[f][m]) begin
              req_l2[t][31:0]  = lsu_pkg::align_store_data(sq[c_abs[f]].data, sq[c_abs[f]].paddr[1:0],
                                                           sq[c_abs[f]].func3[1:0]);
              req_l2[t][35:32] = sq[c_abs[f]].paddr[5:2];
              req_l2[t][39:36] = lsu_pkg::store_strb(sq[c_abs[f]].paddr[1:0], sq[c_abs[f]].func3[1:0])[3:0];
            end
          end
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
