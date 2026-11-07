// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::ub_rmw (taken-path history, no loop trip)
`default_nettype none

// Read-modify-write of one uBTB / L1 set by the head of the train queue.  Every conditional-branch way of the block
// below the event slot steps its counter down; a taken event finds its way by slot or allocates (invalid way, else
// lowest counter).  Outputs the new ways and the mask of the ways whose content changed.
module bpu_ub_rmw import bpu_pkg::*; import bpu_stage_pkg::*; #(
  parameter int WAYS = 4
) (
  input  logic                 ev_valid,
  input  logic [1:0]           ev_kind,
  input  logic [2:0]           ev_slot,
  input  logic [2:0]           ev_ty,
  input  logic [UB_TGT_W-1:0]  ev_tgt,
  input  logic [UB_TAG_W-1:0]  tag,
  input  ub_ent_t              old_ent [WAYS],
  output ub_ent_t              new_ent [WAYS],
  output logic [WAYS-1:0]      wr_mask
);

  localparam logic [1:0] EV_TAKEN = 2'd0;
  localparam logic [1:0] EV_FALL  = 2'd1;

  ub_ent_t        dec_ent [WAYS];     // after the counter steps
  logic [WAYS-1:0] match;
  logic [WAYS-1:0] same_way;          // way that already describes the event branch
  logic            same_any;
  logic [3:0]      limit;
  logic [WAYS-1:0] alloc_way;         // allocation victim (one-hot)
  logic [WAYS-1:0] invalid;
  logic [1:0]      min_ctr;
  logic [WAYS-1:0] min_way;

  // Ref: ub_rmw, counter decrement loop
  always_comb begin
    limit = (ev_kind == EV_TAKEN) ? {1'b0, ev_slot} : (ev_kind == EV_FALL) ? 4'd8 : ({1'b0, ev_slot} + 4'd1);
    for (int w = 0; w < WAYS; w++) begin
      match[w]    = ev_valid && old_ent[w].v && (old_ent[w].tag == tag);
      same_way[w] = match[w] && (ev_kind == EV_TAKEN) && (old_ent[w].slot == ev_slot);
      dec_ent[w]  = old_ent[w];
      if (match[w] && old_ent[w].ty == BR_DIRECT && {1'b0, old_ent[w].slot} < limit && !same_way[w] &&
          old_ent[w].ctr != 2'd0) dec_ent[w].ctr = old_ent[w].ctr - 2'd1;
    end
    same_any = |same_way;
  end

  // Ref: ub_rmw, allocation: first invalid way, else the first way with the lowest counter
  always_comb begin
    for (int w = 0; w < WAYS; w++) invalid[w] = !dec_ent[w].v;
    min_ctr = 2'd3;
    for (int w = 0; w < WAYS; w++) if (dec_ent[w].ctr < min_ctr) min_ctr = dec_ent[w].ctr;
    min_way = '0;
    for (int w = WAYS - 1; w >= 0; w--) if (dec_ent[w].ctr == min_ctr) min_way = WAYS'(1) << w;
    alloc_way = '0;
    for (int w = WAYS - 1; w >= 0; w--) if (invalid[w]) alloc_way = WAYS'(1) << w;
    if (alloc_way == '0) alloc_way = min_way;
  end

  // Ref: ub_rmw, UE_TAKEN update / allocate
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      new_ent[w] = dec_ent[w];
      if (ev_valid && ev_kind == EV_TAKEN) begin
        if (same_any ? same_way[w] : alloc_way[w]) begin
          new_ent[w].v   = 1'b1;
          new_ent[w].tag = tag;
          new_ent[w].slot = ev_slot;
          new_ent[w].ty  = ev_ty;
          new_ent[w].tgt = ev_tgt;
          if (same_any) new_ent[w].ctr = (ev_ty == BR_DIRECT && old_ent[w].ctr != 2'd3) ? old_ent[w].ctr + 2'd1 : 2'd3;
          else          new_ent[w].ctr = (ev_ty == BR_DIRECT) ? 2'd2 : 2'd3;
        end
      end
      wr_mask[w] = ev_valid && (new_ent[w] != old_ent[w]);
    end
  end

endmodule

`default_nettype wire
