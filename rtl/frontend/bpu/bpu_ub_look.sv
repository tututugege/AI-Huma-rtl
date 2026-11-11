// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::s0_lookup (history mode: nd fields dead, loop exit off)
`default_nettype none

// Guess of one block from the ways of its set: the lowest-slot way that matches the block start and is predicted taken
// wins (conditional branches need ctr >= 2).  RET with a non-empty RAS takes the RAS top as target.  The taken-path
// history pushes HSYM_W bits folded from the branch pc and the final target; a miss pushes nothing.
module bpu_ub_look import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; #(
  parameter int WAYS = 4
) (
  input  ub_ent_t        ent [WAYS],
  input  logic [UB_TAG_W-1:0] tag,
  input  logic [XLEN_BITS-1:0]    base,
  input  logic [XLEN_BITS-1:0]    bnd,
  input  logic           ras_nonempty,
  input  logic [XLEN_BITS-1:0]    ras_top,
  output pred_t          g
);

  logic [WAYS-1:0] match;
  logic [WAYS-1:0] cand;
  logic [2:0]      best_slot;
  logic [WAYS-1:0] best_way;
  logic            any_cand;
  logic [2:0]      e_slot;
  logic [2:0]      e_ty;
  logic [UB_TGT_W-1:0] e_tgt;
  logic [XLEN_BITS-1:0]     bpc;

  // Ref: s0_lookup, candidate selection
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      match[w] = ent[w].v && (ent[w].tag == tag);
      cand[w]  = match[w] && ((base + XLEN_BITS'(ent[w].slot) * XLEN_BITS'(4)) < bnd) &&
                 (ent[w].ty != BR_DIRECT || ent[w].ctr >= 2'd2);
    end
    any_cand  = |cand;
    best_slot = 3'd7;
    for (int w = 0; w < WAYS; w++) if (cand[w] && ent[w].slot < best_slot) best_slot = ent[w].slot;
    best_way = '0;
    for (int w = WAYS - 1; w >= 0; w--) if (cand[w] && ent[w].slot == best_slot) best_way = WAYS'(1) << w;
  end

  always_comb begin
    e_slot = '0; e_ty = '0; e_tgt = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (best_way[w]) begin
        e_slot = ent[w].slot; e_ty = ent[w].ty; e_tgt = ent[w].tgt;
      end
    end
    bpc = base + XLEN_BITS'(e_slot) * XLEN_BITS'(4);
    g = '0;
    g.hit = |match;
    if (any_cand) begin
      g.taken = 1'b1;
      g.slot  = e_slot;
      g.ty    = e_ty;
      g.next  = (e_ty == BR_RET && ras_nonempty) ? ras_top : {e_tgt, 2'b00};
      g.hbits = hsym_of(bpc, g.next);
      if (e_ty == BR_CALL || e_ty == BR_ICALL) begin
        g.ras_op  = 2'd1;
        g.ras_val = bpc + XLEN_BITS'(4);
      end else if (e_ty == BR_RET) begin
        g.ras_op = 2'd2;
      end
    end else begin
      g.next = bnd;
    end
  end

endmodule

`default_nettype wire
