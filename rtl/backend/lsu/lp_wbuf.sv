// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (EXP-024 write buffer: comb_lsu2dcache_stq_p, wb_response)
`default_nettype none

// Write buffer of the committed-store drain: NWB entries of up to two stores of one cache line.  The stores stay in the
// STQ (they retire when their response arrives); an entry only groups them: the first store is the leader (its request
// carries the second store as lane 2), the second one is a follower that completes with the leader's response.
//   decision (registers only): an entry that is waiting, ready (all its stores are drain-ready) and not blocked by an
//     older entry (byte overlap) is sent on the next free port, oldest first;
//   insertion (after the decision, registered, lp_wbstep): up to NINS committed stores of the STQ, oldest first, merge
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
  logic [lsu_pkg::SW:0] s0 [NWB], s1 [NWB];            // byte strobes of the two stores
  logic [NWB-1:0] cand, issue, rdy_e;
  logic [NWB-1:0] blk_e;
  always_comb begin
    for (int e = 0; e < NWB; e++) begin
      s0[e] = lsu_pkg::store_strb(ent_q[e].a0[lsu_pkg::OW-1:0], ent_q[e].f0);
      s1[e] = lsu_pkg::store_strb(ent_q[e].a1[lsu_pkg::OW-1:0], ent_q[e].f1);
      rdy_e[e] = d_rdy[ent_q[e].m0] && (!ent_q[e].two || d_rdy[ent_q[e].m1]);
    end
    for (int e = 0; e < NWB; e++) begin
      blk_e[e] = 1'b0;
      for (int o = 0; o < NWB; o++) begin
        if (lt_q[o][e] && v_w[o]) begin
          if (ent_q[e].a0[31:lsu_pkg::OW] == ent_q[o].a0[31:lsu_pkg::OW] &&
              (s0[e] & lsu_pkg::store_strb(ent_q[o].a0[lsu_pkg::OW-1:0], ent_q[o].f0)) != '0) blk_e[e] = 1'b1;
          if (ent_q[o].two && ent_q[e].a0[31:lsu_pkg::OW] == ent_q[o].a1[31:lsu_pkg::OW] &&
              (s0[e] & lsu_pkg::store_strb(ent_q[o].a1[lsu_pkg::OW-1:0], ent_q[o].f1)) != '0) blk_e[e] = 1'b1;
          if (ent_q[e].two && ent_q[e].a1[31:lsu_pkg::OW] == ent_q[o].a0[31:lsu_pkg::OW] &&
              (s1[e] & lsu_pkg::store_strb(ent_q[o].a0[lsu_pkg::OW-1:0], ent_q[o].f0)) != '0) blk_e[e] = 1'b1;
          if (ent_q[e].two && ent_q[o].two && ent_q[e].a1[31:lsu_pkg::OW] == ent_q[o].a1[31:lsu_pkg::OW] &&
              (s1[e] & lsu_pkg::store_strb(ent_q[o].a1[lsu_pkg::OW-1:0], ent_q[o].f1)) != '0) blk_e[e] = 1'b1;
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
          req_data[t] = lsu_pkg::align_store_data(ent_q[e].d0, ent_q[e].a0[lsu_pkg::OW-1:0], ent_q[e].f0);
          req_strb[t] = s0[e];
          req_id[t] = ent_q[e].m0;
          if (ent_q[e].two) begin
            req_l2[t] = {s1[e][lsu_pkg::SW-1:0], ent_q[e].a1[5:lsu_pkg::OW],
                         lsu_pkg::align_store_data(ent_q[e].d1, ent_q[e].a1[lsu_pkg::OW-1:0], ent_q[e].f1)};
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
  logic [SQ-1:0]   ins_vec, ins_rot;
  /* verilator lint_off UNUSEDSIGNAL */  // primitive outputs not needed here
  logic [SQ-1:0]   i_oh [NINS];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [SQW-1:0]  i_pos [NINS];
  logic [NINS-1:0] i_v;
  always_comb begin
    for (int j = 0; j < SQ; j++) ins_vec[j] = sq[j].cmt && !wbi_v[j];
    ins_rot = SQ'(rotr64(64'(ins_vec), head_q));
  end
  lp_pickn #(.N(SQ), .K(NINS)) u_i (.vec(ins_rot), .onehot(i_oh), .idx(i_pos), .v(i_v));

  logic [NINS-1:0] mk;
  logic [SQW-1:0]  jk [NINS];
  wbi_t            sk [NINS];
  wbs_t            ent_0, ent_n;
  ltm_t            lt_0, lt_n;
  wbb_t            b_0;
  always_comb begin
    logic [NWB-1:0] yng;
    for (int e = 0; e < NWB; e++) begin
      ent_0[e] = ent_q[e];
      ent_0[e].v = v_w[e] && !r_hit[e];
      ent_0[e].st = issue[e] || (st_w[e] && !r_rep[e]);
      lt_0[e] = lt_q[e];
    end
    b_0 = '0;
    b_0.go = 1'b1;
    for (int e = 0; e < NWB; e++) begin   // youngest registered entry
      yng[e] = v_w[e];
      for (int o = 0; o < NWB; o++) if (v_w[o] && lt_q[e][o]) yng[e] = 1'b0;
      if (yng[e]) begin
        b_0.tail = 2'(e);
        b_0.tail_v = 1'b1;
        b_0.t_mg = ent_q[e].mg;
        b_0.t_two = ent_q[e].two;
        b_0.t_line = ent_q[e].line;
      end
    end
  end

  for (genvar k = 0; k < NINS; k++) begin : g_ins
    wbs_t ent_o;
    ltm_t lt_o;
    /* verilator lint_off UNUSEDSIGNAL */  // the last step's batch state is not needed
    wbb_t b_o;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
      jk[k] = i_pos[k] + head_q;
      sk[k].mmio = sq[jk[k]].mmio;
      sk[k].done = sq[jk[k]].done;
      sk[k].lrsc = sq[jk[k]].lrsc;
      sk[k].paddr = sq[jk[k]].paddr;
      sk[k].data = sq[jk[k]].data;
      sk[k].f3 = sq[jk[k]].func3[1:0];
    end
    if (k == 0) begin : g_first
      lp_wbstep u_step (
        .ent_i(ent_0), .lt_i(lt_0), .b_i(b_0), .ent_o(ent_o), .lt_o(lt_o), .b_o(b_o),
        .v_reg(v_w), .st_reg(st_w), .issue(issue), .pick_v(i_v[k]), .jk(jk[k]), .s(sk[k]), .mark(mk[k]));
    end else begin : g_next
      lp_wbstep u_step (
        .ent_i(g_ins[k - 1].ent_o), .lt_i(g_ins[k - 1].lt_o), .b_i(g_ins[k - 1].b_o),
        .ent_o(ent_o), .lt_o(lt_o), .b_o(b_o),
        .v_reg(v_w), .st_reg(st_w), .issue(issue), .pick_v(i_v[k]), .jk(jk[k]), .s(sk[k]), .mark(mk[k]));
    end
  end
  assign ent_n = g_ins[NINS - 1].ent_o;
  assign lt_n = g_ins[NINS - 1].lt_o;
  always_comb begin
    wb_mark = '0;
    for (int k = 0; k < NINS; k++) if (mk[k]) wb_mark[jk[k]] = 1'b1;
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
