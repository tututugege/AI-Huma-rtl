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
  logic [CNTW-1:0] older, end_sum;
  logic [SQ-1:0]   mask_hi, mask_lo, raw_hit, raw_unk;
  logic [SQ-1:0]   hit_hi, hit_lo, hit_hi_rev, hit_lo_rev;
  logic [SQ-1:0]   last_hi_rev, last_lo_rev, last_hi_oh, last_lo_oh, last_oh;
  logic [SQ-1:0]   hi_ge, lo_ge, unk_hi, unk_lo, unk_hi_rev, unk_lo_rev;
  logic            any_hi, any_lo, unk_lo_young, unk_hi_young;

  // Unrotated split around head: hi = [head..SQ-1], lo = [0..head-1] (every entry in lo is younger than hi).
  // Eliminates both 64-bit barrel shifters (rotr64) AND the final (+ head) adder from the CAM critical path!
  always_comb begin
    dst_t   = {snap_flag, snap_idx} - {head_flag, head};
    older   = (CNTW'(dst_t) > count) ? count : CNTW'(dst_t);
    end_sum = {1'b0, head} + older;
    for (int j = 0; j < SQ; j++) begin
      mask_hi[j] = (SQW'(j) >= head) && (CNTW'(j) < end_sum);
      mask_lo[j] = (SQW'(j) <  head) && end_sum[SQW] && (SQW'(j) < end_sum[SQW-1:0]);
    end
  end

  for (genvar j = 0; j < SQ; j++) begin : g_cmp
    logic ov_full, ov_part;
    lp_ovl #(.W(32)) u_full (.lo(paddr), .lf(func3), .so(sq[j].paddr), .sf(sq[j].func3), .ovl(ov_full));
    lp_ovl #(.W(12)) u_part (.lo(voff), .lf(func3), .so(cv_voff[j]), .sf(cv_f3[j]), .ovl(ov_part));
    assign raw_hit[j] = !sq[j].suppress &&
                        (!cv_va[j] ? !(MS && spec_ok) : ((full && sq[j].pa_v) ? ov_full : ov_part));
    assign raw_unk[j] = !sq[j].suppress && !cv_va[j];
  end

  assign hit_hi = mask_hi & raw_hit;
  assign hit_lo = mask_lo & raw_hit;
  assign unk_hi = mask_hi & raw_unk;
  assign unk_lo = mask_lo & raw_unk;

  for (genvar j = 0; j < SQ; j++) begin : g_rev
    assign hit_hi_rev[j]  = hit_hi[SQ-1-j];
    assign hit_lo_rev[j]  = hit_lo[SQ-1-j];
    assign last_hi_oh[j]  = last_hi_rev[SQ-1-j];
    assign last_lo_oh[j]  = last_lo_rev[SQ-1-j];
    assign unk_hi_rev[j]  = unk_hi[SQ-1-j];
    assign unk_lo_rev[j]  = unk_lo[SQ-1-j];
  end

  lp_ffs_p #(.N(SQ)) u_hi (.req(hit_hi_rev), .onehot(last_hi_rev), .any(any_hi), .pre(hi_ge));
  lp_ffs_p #(.N(SQ)) u_lo (.req(hit_lo_rev), .onehot(last_lo_rev), .any(any_lo), .pre(lo_ge));
  assign cand_v  = any_lo || any_hi;
  assign last_oh = any_lo ? last_lo_oh : last_hi_oh;
  ttg_onehot_to_idx #(.N(SQ)) u_idx (.onehot(last_oh), .idx(cand));

  assign unk_lo_young = |(unk_lo_rev & ~lo_ge);
  assign unk_hi_young = |(unk_hi_rev & ~hi_ge);
  assign unk = any_lo ? unk_lo_young : ((|unk_lo) || unk_hi_young);

endmodule

`default_nettype wire
