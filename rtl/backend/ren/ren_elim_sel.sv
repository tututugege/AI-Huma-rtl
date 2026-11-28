// Ref: back-end/Ren.cpp  class Ren  Ren::elim_refs_ok (move elimination: which moves are renamed away)
`default_nettype none

// Move elimination with 6-bit unbounded arch_cnt (max RAT_NUM = 33, never overflows):
// a move-shaped instruction is eliminated unless its source is written by an older eliminated move in the same group
// (1-hop intra-group bypass). Uses pre-decoded S1 raw_hit_src1 so elim[0..N-1] is completely independent of spec_RAT!
module ren_elim_sel
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-1:0] inst_valid,
  input  logic [N-1:0] move_shape,          // addi rd, rs, 0 with real rd and rs (pre-decoded in S1)
  input  logic [N-1:0] raw_hit_src1 [N],    // pre-decoded in S1: dest_en[j] & ~dest_fp[j] & (dest_areg[j]==src1_areg[i])
  output logic [N-1:0] elim
);

  localparam int NW = $clog2(N);  // 3 bits for N = 8
  localparam int ST = NW;         // ceil(log2(N)) = 3 pointer-jumping stages cover up to 2^3 = 8 hops

  logic [N-1:0] cand;
  assign cand = inst_valid & move_shape;

  // Stage 0..ST pointer-jumping state for each lane:
  //   c=1 -> elim[i] = v
  //   c=0 -> elim[i] = elim[ptr] ^ inv
  // Every chain terminates at a lane with c=1 (either !cand or !any_bypass -> v=1).
  // Each stage has its own signals (g_st[s]) so stage s+1 only reads stage s: no signal-level combinational loop
  // (the former [ST+1]-indexed arrays were one signal each, a false UNOPTFLAT loop through the dynamic index).
  for (genvar s = 0; s <= ST; s++) begin : g_st
    logic [N-1:0]  c, v, inv;
    if (s < ST) begin : g_p          // the last stage needs no pointer
      logic [NW-1:0] ptr [N];
    end
  end

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0]  bypass_hit, bypass_rev, pick_rev, pick;
    logic          any_bypass;
    logic [NW-1:0] prod_idx;

    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign bypass_hit[j] = inst_valid[j] & raw_hit_src1[i][j];
      end else begin : g_no
        assign bypass_hit[j] = 1'b0;
      end
      assign bypass_rev[j] = bypass_hit[N-1-j];
      assign pick[j]       = pick_rev[N-1-j];
    end

    ttg_first_set     #(.N(N)) u_byp_pick (.req(bypass_rev), .onehot(pick_rev), .any(any_bypass));
    ttg_onehot_to_idx #(.N(N)) u_byp_idx  (.onehot(pick),    .idx(prod_idx));

    assign g_st[0].c[i]   = !cand[i] || !any_bypass;
    assign g_st[0].v[i]   = cand[i] && !any_bypass;
    assign g_st[0].inv[i] = cand[i] && any_bypass;
    assign g_st[0].g_p.ptr[i] = (cand[i] && any_bypass) ? prod_idx : NW'(i);
  end

  // Pointer-jumping doubling: ST = log2(N) parallel stages resolve all intra-group chains
  for (genvar s = 0; s < ST; s++) begin : g_jump
    for (genvar i = 0; i < N; i++) begin : g_lane
      logic [NW-1:0] p;
      logic          cp, vp, ip;
      assign p  = g_st[s].g_p.ptr[i];
      assign cp = g_st[s].c[p];
      assign vp = g_st[s].v[p];
      assign ip = g_st[s].inv[p];
      assign g_st[s+1].c[i]   = g_st[s].c[i] | cp;
      assign g_st[s+1].v[i]   = g_st[s].c[i] ? g_st[s].v[i] : (cp ? (vp ^ g_st[s].inv[i]) : 1'b0);
      assign g_st[s+1].inv[i] = (g_st[s].c[i] | cp) ? 1'b0 : (g_st[s].inv[i] ^ ip);
      if (s + 1 < ST) begin : g_np
        assign g_st[s+1].g_p.ptr[i] = (g_st[s].c[i] | cp) ? p : g_st[s].g_p.ptr[p];
      end
    end
  end

  assign elim = g_st[ST].v;

  // only v of the last stage is used
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_last;
  assign unused_last = ^{g_st[ST].c, g_st[ST].inv};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
