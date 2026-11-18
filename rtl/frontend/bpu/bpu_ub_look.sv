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

  // Low-depth form of the lookup (same guess; checked against the sequential form by random test).  Per way, in
  // parallel: the tag match, the "slot inside the block" test as a small compare against the block length bnd - base
  // (a few low bits, never a 64-bit add and compare), and everything that follows from the way's entry (block end pc,
  // target, history symbol, RAS value).  The winner is the lowest slot among the candidates (the lowest way on a tie),
  // found by pairwise slot compares; the guess is then one select by the winner, not a chain of selects and adders.
  localparam int SB = SLOT_BYTES;
  logic [WAYS-1:0] match, cand, win;
  logic [7:0]      blk_len;     // bnd - base, 1 .. 32 (the block never ends more than 255 bytes behind its start)
  assign blk_len = bnd[7:0] - base[7:0];

  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      match[w] = ent[w].v && (ent[w].tag == tag);
      cand[w]  = match[w] && ((9'(ent[w].slot) * 9'(SB)) < {1'b0, blk_len}) &&
                 (ent[w].ty != BR_DIRECT || ent[w].ctr >= 2'd2);
    end
    for (int w = 0; w < WAYS; w++) begin
      win[w] = cand[w];
      for (int o = 0; o < WAYS; o++) begin
        if (o != w && cand[o] && !(ent[w].slot < ent[o].slot || (ent[w].slot == ent[o].slot && w < o))) win[w] = 1'b0;
      end
    end
  end

  // per way: what the guess would be if this way wins
  logic [XLEN_BITS-1:0]  w_bpc  [WAYS];
  logic [XLEN_BITS-1:0]  w_next [WAYS];
  logic [XLEN_BITS-1:0]  w_rv   [WAYS];
  logic [HSYM_W-1:0]     w_hb   [WAYS];
  logic [1:0]            w_op   [WAYS];
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      w_bpc[w]  = base + XLEN_BITS'(ent[w].slot) * XLEN_BITS'(SB);
      // the uBTB keeps the full target slot address (model ub_expand)
      w_next[w] = (ent[w].ty == BR_RET && ras_nonempty) ? ras_top : (XLEN_BITS'(ent[w].tgt) << SLOT_SHIFT);
      w_hb[w]   = hsym_of(w_bpc[w], w_next[w]);
      w_rv[w]   = w_bpc[w] + (ent[w].rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
      w_op[w]   = (ent[w].ty == BR_CALL || ent[w].ty == BR_ICALL) ? 2'd1 : (ent[w].ty == BR_RET) ? 2'd2 : 2'd0;
    end
  end

  always_comb begin
    g = '0;
    g.hit = |match;
    if (|cand) begin
      g.taken = 1'b1;
      for (int w = 0; w < WAYS; w++) begin
        if (win[w]) begin
          g.slot    = ent[w].slot;
          g.ty      = ent[w].ty;
          g.rvc     = ent[w].rvc;
          g.next    = w_next[w];
          g.hbits   = w_hb[w];
          g.ras_op  = w_op[w];
          g.ras_val = (w_op[w] == 2'd1) ? w_rv[w] : '0;
        end
      end
    end else begin
      g.next = bnd;
    end
  end

endmodule

`default_nettype wire
