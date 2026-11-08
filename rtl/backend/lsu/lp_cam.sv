// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (stq_cam: partial-address CAM over the STQ, one per load port)
`default_nettype none

// L1 partial STLF CAM of one load slot: 64 parallel comparators; result = the youngest older store that may conflict
// (unknown address always conflicts; page offset + size compare, or the full physical address for a replay whose
// store already has a physical address).  Registers only (plus the STA arrival bypass folded into the cv_* view).
module lp_cam
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic [11:0]         voff,
  input  logic [2:0]          func3,
  input  logic [31:0]         paddr,
  input  logic                full,
  input  logic [SQW-1:0]      snap_idx,
  input  logic                snap_flag,
  input  logic [SQW-1:0]      head,
  input  logic                head_flag,
  input  logic [CNTW-1:0]     count,
  input  logic [SQ-1:0]       cv_va,
  input  logic [11:0]         cv_voff [SQ],
  input  logic [2:0]          cv_f3 [SQ],
  input  lp_stq_t             sq [SQ],
  input  logic                spec_ok,   // memory speculation: the load passes unknown-address stores
  output logic                cand_v,
  output logic [SQW-1:0]      cand,
  output logic                unk        // an older store younger than the candidate was passed with an unknown address
);

  logic [SQW:0]   dst_t;
  logic [CNTW-1:0] older;
  logic [SQ-1:0]  older_mask, hit, hit_rev, last_rev, last_pos, unk_v, unk_rev, hit_ge;
  logic [63:0]    hit_rot;
  logic [SQW-1:0] pos_idx;
  logic           any_hit;

  always_comb begin
    dst_t = {snap_flag, snap_idx} - {head_flag, head};
    older = (CNTW'(dst_t) > count) ? count : CNTW'(dst_t);
    older_mask = SQ'(rotl64(64'((older >= CNTW'(SQ)) ? '1 : ~('1 << older[SQW-1:0])), head));
  end

  for (genvar j = 0; j < SQ; j++) begin : g_cmp
    logic ov_full, ov_part;
    assign ov_full = rel32(paddr, func3, sq[j].paddr, sq[j].func3) != 2'd0;
    assign ov_part = rel12(voff, func3, cv_voff[j], cv_f3[j]) != 2'd0;
    assign hit[j] = older_mask[j] && !sq[j].suppress &&
                    (!cv_va[j] ? !(MS && spec_ok) : ((full && sq[j].pa_v) ? ov_full : ov_part));
    assign unk_v[j] = older_mask[j] && !sq[j].suppress && !cv_va[j];
  end

  assign hit_rot = rotr64(64'(hit), head);
  for (genvar j = 0; j < SQ; j++) begin : g_rev
    assign hit_rev[j] = hit_rot[SQ-1-j];
    assign last_pos[j] = last_rev[SQ-1-j];
  end
  lp_ffs #(.N(SQ)) u_last (.req(hit_rev), .onehot(last_rev), .any(any_hit));
  ttg_onehot_to_idx #(.N(SQ)) u_idx (.onehot(last_pos), .idx(pos_idx));
  assign cand_v = any_hit;
  assign cand = pos_idx + head;

  // memory speculation: youngest passed (unknown-address) store younger than the youngest hit.  In the reversed
  // rank order (index 0 = youngest) that is an unknown bit with no hit at or before it: prefix-OR of the hits.
  logic [SQ-1:0] unk_rot;
  always_comb begin
    unk_rot = SQ'(rotr64(64'(unk_v), head));
    hit_ge = hit_rev;
    for (int s = 1; s < SQ; s = s * 2) hit_ge = hit_ge | (hit_ge << s);
  end
  for (genvar j = 0; j < SQ; j++) begin : g_unk
    assign unk_rev[j] = unk_rot[SQ-1-j];
  end
  assign unk = MS && spec_ok && (|(unk_rev & ~hit_ge));

endmodule

`default_nettype wire
