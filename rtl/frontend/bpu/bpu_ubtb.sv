// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::ub0_ / ub1_ (S0 uBTB, S1 L1 table), commit-side training
`default_nettype none

// S0 uBTB (128 x 4 way, read in the S0 cycle) and S1 L1 table (512 x 2 way, read in the S1 cycle) with their common
// training path: commit stream -> block tracker -> train queue -> one read-modify-write of both tables per cycle.
// The lookups are pure functions of the registered block start (and the RAS top for returns).
module bpu_ubtb import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // commit stream
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [XLEN_BITS-1:0]         target   [NCOMMIT],
  // S0 lookup
  input  logic [XLEN_BITS-1:0]         s0_base,
  input  logic [XLEN_BITS-1:0]         s0_bnd,
  input  logic                s0_ras_nonempty,
  input  logic [XLEN_BITS-1:0]         s0_ras_top,
  output pred_t               s0_guess,
  // S1 lookup
  input  logic [XLEN_BITS-1:0]         s1_base,
  input  logic [XLEN_BITS-1:0]         s1_bnd,
  input  logic                s1_ras_nonempty,
  input  logic [XLEN_BITS-1:0]         s1_ras_top,
  output pred_t               s1_guess
);

  logic [NCOMMIT-1:0] ev_valid;
  ub_ev_t             ev [NCOMMIT];
  logic               head_valid;
  ub_ev_t             head;

  bpu_ub_track u_track (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .pred_dir, .target, .ev_valid, .ev
  );
  bpu_ub_tq u_tq (.clk, .rst_n, .ev_valid, .ev, .head_valid, .head);

  // ---- S0 table ----
  ub_ent_t               ub_rd_ent [UB_WAYS];
  ub_ent_t               ub_tr_ent [UB_WAYS];
  ub_ent_t               ub_new_ent [UB_WAYS];
  logic [UB_WAYS-1:0]    ub_wr_mask;

  bpu_ub_tab #(.SET_W(UB_SET_W), .WAYS(UB_WAYS)) u_ub (
    .clk, .rst_n, .rd_set(ub_set_of(s0_base[31:2])), .rd_ent(ub_rd_ent), .tr_set(ub_set_of(head.start)),
    .tr_ent(ub_tr_ent), .wr_mask(ub_wr_mask), .wr_set(ub_set_of(head.start)), .wr_ent(ub_new_ent)
  );
  bpu_ub_rmw #(.WAYS(UB_WAYS)) u_ub_rmw (
    .ev_valid(head_valid), .ev_kind(head.kind), .ev_slot(head.slot), .ev_ty(head.ty), .ev_tgt(head.tgt),
    .tag(ub_tag_of(head.start)), .old_ent(ub_tr_ent), .new_ent(ub_new_ent),
    .wr_mask(ub_wr_mask)
  );
  bpu_ub_look #(.WAYS(UB_WAYS)) u_ub_look (
    .ent(ub_rd_ent), .tag(ub_tag_of(s0_base[31:2])), .base(s0_base), .bnd(s0_bnd), .ras_nonempty(s0_ras_nonempty),
    .ras_top(s0_ras_top), .g(s0_guess)
  );

  // ---- S1 table ----
  ub_ent_t               l1_rd_ent [L1_WAYS];
  ub_ent_t               l1_tr_ent [L1_WAYS];
  ub_ent_t               l1_new_ent [L1_WAYS];
  logic [L1_WAYS-1:0]    l1_wr_mask;

  bpu_ub_tab #(.SET_W(L1_SET_W), .WAYS(L1_WAYS)) u_l1 (
    .clk, .rst_n, .rd_set(l1_set_of(s1_base[31:2])), .rd_ent(l1_rd_ent), .tr_set(l1_set_of(head.start)),
    .tr_ent(l1_tr_ent), .wr_mask(l1_wr_mask), .wr_set(l1_set_of(head.start)), .wr_ent(l1_new_ent)
  );
  bpu_ub_rmw #(.WAYS(L1_WAYS)) u_l1_rmw (
    .ev_valid(head_valid), .ev_kind(head.kind), .ev_slot(head.slot), .ev_ty(head.ty), .ev_tgt(head.tgt),
    .tag(l1_tag_of(head.start)), .old_ent(l1_tr_ent), .new_ent(l1_new_ent),
    .wr_mask(l1_wr_mask)
  );
  bpu_ub_look #(.WAYS(L1_WAYS)) u_l1_look (
    .ent(l1_rd_ent), .tag(l1_tag_of(s1_base[31:2])), .base(s1_base), .bnd(s1_bnd), .ras_nonempty(s1_ras_nonempty),
    .ras_top(s1_ras_top), .g(s1_guess)
  );

endmodule

`default_nettype wire
