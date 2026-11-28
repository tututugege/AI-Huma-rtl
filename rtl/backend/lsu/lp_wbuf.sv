// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (EXP-024 write buffer: comb_lsu2dcache_stq_p, wb_response)
`default_nettype none

// Write buffer of the committed-store drain: NWB entries of up to two stores of one cache line.  The stores stay in the
// STQ (they retire when their response arrives); an entry only groups them: the first store is the leader (its request
// carries the second store as lane 2), the second one is a follower that completes with the leader's response.
//   decision (registers only): an entry that is waiting, ready (all its stores are drain-ready) and not blocked by an
//     older entry (byte overlap) is sent on the next free port, oldest first;
//   insertion (after the decision, registered): up to NINS committed stores of the STQ, oldest first, merge
//     into the youngest entry when it is still waiting and not sent in this cycle, else start a new entry;
//   response: the response of the leader frees the entry (hit) or makes it wait again.
module lp_wbuf
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  lp_stq_t             sq [SQ],
  input  logic [SQ-1:0]       d_rdy,
  input  logic [SQ-1:0]       wbi_v,            // store already handled by the insertion
  input  logic [SQW-1:0]      head_q,
  input  logic [NST-1:0]      retry_busy,
  input  logic [NST-1:0]      dcs_valid,
  input  logic [31:0]         dcs_req_id [NST],
  input  logic [1:0]          dcs_replay [NST],
  output logic [SQ-1:0]       wb_mark,
  output logic [SQ-1:0]       dr_pick,
  output logic [SQ-1:0]       dr_fol,
  output logic [SQW-1:0]      dr_ml [SQ],
  output logic [NST-1:0]      req_valid,
  output logic [31:0]         req_addr [NST],
  output logic [XLEN_BITS-1:0]         req_data [NST],
  output logic [DST_STRB_W-1:0] req_strb [NST],
  output logic [DST_L2_W-1:0]  req_l2 [NST],
  output logic [SQW-1:0]      req_id [NST]
);

  localparam int NINS = 4;

  wbe_t           ent_q [NWB];
  logic [NWB-1:0] lt_q [NWB];                    // lt_q[e][o]: entry e is older than entry o
  logic [NWB-1:0] v_w, st_w;
  always_comb begin
    for (int e = 0; e < NWB; e++) begin
      v_w[e] = ent_q[e].v;
      st_w[e] = ent_q[e].st;
    end
  end

  // ---- free ports ----
  logic [NDR-1:0] free_p;
  logic [NDR-1:0] f_oh [NDR];
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [1:0]     f_ix [NDR];
  logic [NDR-1:0] f_v;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    for (int t = 0; t < NDR; t++) free_p[t] = !retry_busy[t];
  end
  lp_pickn #(.N(NDR), .K(NDR), .IW(2)) u_f (.vec(free_p), .onehot(f_oh), .idx(f_ix), .v(f_v));

  // ---- decision: ready, not blocked by an older entry, the oldest ones take the free ports ----
  logic [SW:0] s0 [NWB], s1 [NWB];            // byte strobes of the two stores
  logic [NWB-1:0] cand, issue, rdy_e;
  logic [NWB-1:0] blk_e;
  always_comb begin
    for (int e = 0; e < NWB; e++) begin
      s0[e] = store_strb(ent_q[e].a0[OW-1:0], ent_q[e].f0);
      s1[e] = store_strb(ent_q[e].a1[OW-1:0], ent_q[e].f1);
      rdy_e[e] = d_rdy[ent_q[e].m0] && (!ent_q[e].two || d_rdy[ent_q[e].m1]);
    end
    for (int e = 0; e < NWB; e++) begin
      blk_e[e] = 1'b0;
      for (int o = 0; o < NWB; o++) begin
        if (lt_q[o][e] && v_w[o]) begin
          if (ent_q[e].a0[31:OW] == ent_q[o].a0[31:OW] &&
              (s0[e] & store_strb(ent_q[o].a0[OW-1:0], ent_q[o].f0)) != '0) blk_e[e] = 1'b1;
          if (ent_q[o].two && ent_q[e].a0[31:OW] == ent_q[o].a1[31:OW] &&
              (s0[e] & store_strb(ent_q[o].a1[OW-1:0], ent_q[o].f1)) != '0) blk_e[e] = 1'b1;
          if (ent_q[e].two && ent_q[e].a1[31:OW] == ent_q[o].a0[31:OW] &&
              (s1[e] & store_strb(ent_q[o].a0[OW-1:0], ent_q[o].f0)) != '0) blk_e[e] = 1'b1;
          if (ent_q[e].two && ent_q[o].two && ent_q[e].a1[31:OW] == ent_q[o].a1[31:OW] &&
              (s1[e] & store_strb(ent_q[o].a1[OW-1:0], ent_q[o].f1)) != '0) blk_e[e] = 1'b1;
        end
      end
      cand[e] = v_w[e] && !st_w[e] && rdy_e[e] && !blk_e[e];
    end
  end

  logic [2:0]     rk [NWB];                      // candidates older than entry e
  logic [NDR-1:0] e_port [NWB];                  // port of an issuing entry (one-hot)
  always_comb begin
    for (int e = 0; e < NWB; e++) begin
      rk[e] = '0;
      for (int o = 0; o < NWB; o++) if (cand[o] && lt_q[o][e]) rk[e] = rk[e] + 3'd1;
      e_port[e] = '0;
      for (int r = 0; r < NDR; r++) if (rk[e] == 3'(r)) e_port[e] = f_oh[r];
      issue[e] = cand[e] && e_port[e] != '0;
    end
  end

  // ---- STQ marks of the sent entries ----
  always_comb begin
    dr_pick = '0;
    dr_fol = '0;
    for (int j = 0; j < SQ; j++) dr_ml[j] = '0;
    for (int e = 0; e < NWB; e++) begin
      if (issue[e]) begin
        dr_pick[ent_q[e].m0] = 1'b1;
        if (ent_q[e].two) begin
          dr_pick[ent_q[e].m1] = 1'b1;
          dr_fol[ent_q[e].m1] = 1'b1;
          dr_ml[ent_q[e].m1] = ent_q[e].m0;
        end
      end
    end
  end

  // ---- DCache requests ----
  always_comb begin
    for (int t = 0; t < NST; t++) begin
      req_valid[t] = 1'b0;
      req_addr[t] = '0;
      req_data[t] = '0;
      req_strb[t] = '0;
      req_l2[t] = '0;
      req_id[t] = '0;
      for (int e = 0; e < NWB; e++) begin
        if (t < NDR && issue[e] && e_port[e][t]) begin
          req_valid[t] = 1'b1;
          req_addr[t] = ent_q[e].a0;
          req_data[t] = align_store_data(ent_q[e].d0, ent_q[e].a0[OW-1:0], ent_q[e].f0);
          req_strb[t] = s0[e];
          req_id[t] = ent_q[e].m0;
          if (ent_q[e].two) begin
            req_l2[t] = {s1[e][SW-1:0], ent_q[e].a1[5:OW],
                         align_store_data(ent_q[e].d1, ent_q[e].a1[OW-1:0], ent_q[e].f1)};
          end
        end
      end
    end
  end

  // ---- responses of the leaders ----
  logic [NWB-1:0] r_hit, r_rep;
  always_comb begin
    r_hit = '0;
    r_rep = '0;
    for (int e = 0; e < NWB; e++)
      for (int k = 0; k < NST; k++)
        if (v_w[e] && st_w[e] && dcs_valid[k] && dcs_req_id[k] == 32'(ent_q[e].m0)) begin
          r_hit[e] = r_hit[e] | (dcs_replay[k] == RT_HIT);
          r_rep[e] = r_rep[e] | (dcs_replay[k] != RT_HIT);
        end
  end

  // ---- insertion: the first NINS committed stores that the buffer has not handled yet ----
  // Unrotated hi/lo split avoids 64b barrel rotate + (i_pos + head_q) adder + 5->32 decoder.
  logic [SQ-1:0]   ins_vec, ge_head, hi_vec, lo_vec;
  logic [SQ-1:0]   hi_oh [NINS], lo_oh [NINS], sel_oh [NINS];
  logic [NINS-1:0] hi_v, lo_v, i_v;
  always_comb begin
    for (int j = 0; j < SQ; j++) begin
      ins_vec[j] = sq[j].cmt && !wbi_v[j];
      ge_head[j] = (SQW'(j) >= head_q);
    end
    hi_vec = ins_vec & ge_head;
    lo_vec = ins_vec & ~ge_head;
  end
  ttg_pick_k #(.N(SQ), .K(NINS)) u_pk_hi (.req(hi_vec), .pick_oh(hi_oh), .valid(hi_v));
  ttg_pick_k #(.N(SQ), .K(NINS)) u_pk_lo (.req(lo_vec), .pick_oh(lo_oh), .valid(lo_v));

  always_comb begin
    // k = 0
    sel_oh[0] = hi_v[0] ? hi_oh[0] : lo_oh[0];
    i_v[0]    = hi_v[0] ? 1'b1     : lo_v[0];
    // k = 1
    sel_oh[1] = hi_v[1] ? hi_oh[1] : (hi_v[0] ? lo_oh[0] : lo_oh[1]);
    i_v[1]    = hi_v[1] ? 1'b1     : (hi_v[0] ? lo_v[0]  : lo_v[1]);
    // k = 2
    sel_oh[2] = hi_v[2] ? hi_oh[2] : (hi_v[1] ? lo_oh[0] : (hi_v[0] ? lo_oh[1] : lo_oh[2]));
    i_v[2]    = hi_v[2] ? 1'b1     : (hi_v[1] ? lo_v[0]  : (hi_v[0] ? lo_v[1]  : lo_v[2]));
    // k = 3
    sel_oh[3] = hi_v[3] ? hi_oh[3] : (hi_v[2] ? lo_oh[0] : (hi_v[1] ? lo_oh[1] : (hi_v[0] ? lo_oh[2] : lo_oh[3])));
    i_v[3]    = hi_v[3] ? 1'b1     : (hi_v[2] ? lo_v[0]  : (hi_v[1] ? lo_v[1]  : (hi_v[0] ? lo_v[2]  : lo_v[3])));
  end

  logic [SQW-1:0]  jk [NINS];
  wbi_t            sk [NINS];
  wbi_t            sq_wbi [SQ];
  always_comb begin
    for (int j = 0; j < SQ; j++) begin
      sq_wbi[j].mmio  = sq[j].mmio;
      sq_wbi[j].done  = sq[j].done;
      sq_wbi[j].lrsc  = sq[j].lrsc;
      sq_wbi[j].paddr = sq[j].paddr;
      sq_wbi[j].data  = sq[j].data;
      sq_wbi[j].f3    = sq[j].func3[1:0];
    end
  end
  for (genvar k = 0; k < NINS; k++) begin : g_sel
    ttg_onehot_to_idx #(.N(SQ), .IDXW(SQW)) u_ix (.onehot(sel_oh[k]), .idx(jk[k]));
    ttg_onehot_mux #(.N(SQ), .W($bits(wbi_t))) u_mx (.sel(sel_oh[k]), .data(sq_wbi), .out(sk[k]));
  end

  // Pre-compute free WB slots from ~v_w in parallel (lowest index first).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NWB-1:0] free_oh [NWB];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0]     free_idx [NWB];
  logic [NWB-1:0] free_v;
  lp_pickn #(.N(NWB), .K(NWB), .IW(2)) u_free (.vec(~v_w), .onehot(free_oh), .idx(free_idx), .v(free_v));

  // Pre-compute all 6 pairwise 26-bit cache-line matches in parallel (off the 4-step control chain).
  logic [NINS-1:0] same_line [NINS];
  always_comb begin
    for (int a = 0; a < NINS; a++) begin
      same_line[a] = '0;
      for (int b = a + 1; b < NINS; b++)
        same_line[a][b] = (sk[a].paddr[31:6] == sk[b].paddr[31:6]);
    end
  end

  // Flattened 4-step control-only plan (no 26b comparators or 240b payload muxes on the chain).
  logic [NINS-1:0] mk;
  logic [NINS-1:0] act_alloc, act_merge;
  logic [1:0]      alloc_slot [NINS], merge_slot [NINS];
  logic [NWB-1:0]  new_e;
  always_comb begin
    logic       go, open_v;
    logic [1:0] open_k, open_slot;
    logic [2:0] n_alloc;
    go        = 1'b1;
    open_v    = 1'b0;
    open_k    = 2'd0;
    open_slot = 2'd0;
    n_alloc   = 3'd0;
    mk        = '0;
    act_alloc = '0;
    act_merge = '0;
    new_e     = '0;
    for (int k = 0; k < NINS; k++) begin
      alloc_slot[k] = 2'd0;
      merge_slot[k] = 2'd0;
      if (go && i_v[k]) begin
        if (sk[k].mmio || sk[k].done) begin
          mk[k] = 1'b1;
        end else if (open_v && !sk[k].lrsc && same_line[open_k][k]) begin
          act_merge[k]  = 1'b1;
          merge_slot[k] = open_slot;
          open_v        = 1'b0;
          mk[k]         = 1'b1;
        end else if (n_alloc < 3'(NWB) && free_v[n_alloc[1:0]]) begin
          act_alloc[k]  = 1'b1;
          alloc_slot[k] = free_idx[n_alloc[1:0]];
          new_e[free_idx[n_alloc[1:0]]] = 1'b1;
          open_v        = !sk[k].lrsc;
          open_k        = 2'(k);
          open_slot     = free_idx[n_alloc[1:0]];
          n_alloc       = n_alloc + 3'd1;
          mk[k]         = 1'b1;
        end else begin
          go = 1'b0;
        end
      end
    end
  end

  // Single-level parallel payload + age-matrix update of all insertions.
  wbs_t ent_0, ent_n;
  ltm_t lt_n;
  always_comb begin
    for (int e = 0; e < NWB; e++) begin
      ent_0[e]    = ent_q[e];
      ent_0[e].v  = v_w[e] && !r_hit[e];
      ent_0[e].st = issue[e] || (st_w[e] && !r_rep[e]);

      ent_n[e] = ent_0[e];
      if (new_e[e]) begin
        ent_n[e].v   = 1'b1;
        ent_n[e].st  = 1'b0;
        ent_n[e].two = 1'b0;
        for (int k = 0; k < NINS; k++) begin
          if (act_alloc[k] && alloc_slot[k] == 2'(e)) begin
            ent_n[e].mg   = !sk[k].lrsc;
            ent_n[e].line = sk[k].paddr[31:6];
            ent_n[e].m0   = jk[k];
            ent_n[e].a0   = sk[k].paddr;
            ent_n[e].d0   = sk[k].data;
            ent_n[e].f0   = sk[k].f3;
          end
        end
        for (int k = 1; k < NINS; k++) begin
          if (act_merge[k] && merge_slot[k] == 2'(e)) begin
            ent_n[e].two = 1'b1;
            ent_n[e].m1  = jk[k];
            ent_n[e].a1  = sk[k].paddr;
            ent_n[e].d1  = sk[k].data;
            ent_n[e].f1  = sk[k].f3;
          end
        end
      end
    end

    // Age matrix: newly allocated slots are allocated in strictly increasing slot index order.
    for (int o = 0; o < NWB; o++) begin
      for (int e = 0; e < NWB; e++) begin
        if (new_e[e])      lt_n[o][e] = v_w[o] || (new_e[o] && (o < e));
        else if (new_e[o]) lt_n[o][e] = 1'b0;
        else               lt_n[o][e] = lt_q[o][e];
      end
    end

    wb_mark = '0;
    for (int k = 0; k < NINS; k++) if (mk[k]) wb_mark |= sel_oh[k];
  end

  always_ff @(posedge clk) begin
    for (int e = 0; e < NWB; e++) begin
      ent_q[e] <= ent_n[e];
      lt_q[e] <= lt_n[e];
      if (!rst_n) begin
        ent_q[e].v <= 1'b0;
        ent_q[e].st <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
