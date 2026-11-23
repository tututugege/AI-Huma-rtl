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

  logic [SQW:0]    dst_t;
  logic [CNTW-1:0] older;
  logic [SQ-1:0]   mask_unrot, raw_hit, raw_unk, raw_hit_rot, raw_unk_rot;
  logic [SQ-1:0]   hit_rot, hit_rev, last_rev, last_pos, unk_rot, unk_rev, hit_ge;
  logic [SQW-1:0]  pos_idx;
  logic            any_hit;

  always_comb begin
    dst_t = {snap_flag, snap_idx} - {head_flag, head};
    older = (CNTW'(dst_t) > count) ? count : CNTW'(dst_t);
    for (int i = 0; i < SQ; i++) mask_unrot[i] = (CNTW'(i) < older);
  end

  for (genvar j = 0; j < SQ; j++) begin : g_cmp
    logic ov_full, ov_part;
    lp_ovl #(.W(32)) u_full (.lo(paddr), .lf(func3), .so(sq[j].paddr), .sf(sq[j].func3), .ovl(ov_full));
    lp_ovl #(.W(12)) u_part (.lo(voff), .lf(func3), .so(cv_voff[j]), .sf(cv_f3[j]), .ovl(ov_part));
    assign raw_hit[j] = !sq[j].suppress &&
                        (!cv_va[j] ? !(MS && spec_ok) : ((full && sq[j].pa_v) ? ov_full : ov_part));
    assign raw_unk[j] = !sq[j].suppress && !cv_va[j];
  end

  // Algebraic identity: rotr64(rotl64(mask_unrot, head) & raw, head) == mask_unrot & rotr64(raw, head).
  // Removes rotl64 and rotr64 from the late-arriving snap_idx -> older -> hit_rot critical path!
  assign raw_hit_rot = SQ'(rotr64(64'(raw_hit), head));
  assign raw_unk_rot = SQ'(rotr64(64'(raw_unk), head));
  assign hit_rot     = mask_unrot & raw_hit_rot;
  assign unk_rot     = mask_unrot & raw_unk_rot;

  for (genvar j = 0; j < SQ; j++) begin : g_rev
    assign hit_rev[j]  = hit_rot[SQ-1-j];
    assign last_pos[j] = last_rev[SQ-1-j];
    assign unk_rev[j]  = unk_rot[SQ-1-j];
  end
  lp_ffs_p #(.N(SQ)) u_last (.req(hit_rev), .onehot(last_rev), .any(any_hit), .pre(hit_ge));
  ttg_onehot_to_idx #(.N(SQ)) u_idx (.onehot(last_pos), .idx(pos_idx));
  assign cand_v = any_hit;
  assign cand   = pos_idx + head;

  // memory speculation: youngest passed (unknown-address) store younger than the youngest hit.  In the reversed
  // rank order (index 0 = youngest) that is an unknown bit with no hit at or before it: the prefix-OR of the hits
  // (hit_ge, shared with the find-first-set above).
  assign unk = (|(unk_rev & ~hit_ge));   // 0 when the load may not pass (an unknown store is then a hit)

endmodule

`default_nettype wire
