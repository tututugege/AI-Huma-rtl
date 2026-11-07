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
  output logic                cand_v,
  output logic [SQW-1:0]      cand
);

  logic [SQW:0]   dst_t;
  logic [CNTW-1:0] older;
  logic [SQ-1:0]  older_mask, hit, hit_rev, last_rev, last_pos;
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
                    (!cv_va[j] || ((full && sq[j].pa_v) ? ov_full : ov_part));
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

endmodule

`default_nettype wire
