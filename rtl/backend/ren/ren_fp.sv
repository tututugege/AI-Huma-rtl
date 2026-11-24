// Ref: back-end/Ren.cpp  class Ren  (F/D rename: fp_spec_RAT, fp_arch_RAT, fp_free_list, sparse checkpoints + walk)
`default_nettype none

// FP rename domain: the second RAT / free list / sparse checkpoints of the rename stage. Instantiated by ren_core only
// when the core has an FP register file (FPRF_NUM > 0). The slot handshake (stall on an empty list, in order) stays in
// ren_core; this module only reports which FP-destination slots were served.
module ren_fp
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int NK = REN_CKPT_NUM,
  parameter int KW = (NK > 1) ? $clog2(NK) : 1,
  parameter int CW = $clog2(C + 1)
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [N-1:0]   inst_valid,
  input  ren_inst_t      inst [N],
  input  logic [N-1:0]   fire,
  input  logic           dec_mispred,
  input  logic           rob_flush,
  // shared sparse checkpoint & walk control from ren_ckpt_ctl
  input  logic           ckpt_wr_en,
  input  logic [KW-1:0]  ckpt_wr_slot,
  input  logic [N-1:0]   ckpt_wr_lane_oh,
  input  logic           ckpt_rd_hit,
  input  logic [KW-1:0]  ckpt_rd_slot,
  input  logic           walk_active,
  input  logic [N-1:0]   walk_slot_en,
  input  ren_log_entry_t walk_entry [N],
  // commit side (from local ren_log)
  input  logic [C-1:0]   reclaim,                   // commit slot retires an FP destination
  input  areg_t          c_dest_areg [C],
  input  preg_t          c_dest_preg [C],
  input  preg_t          c_old_dest_preg [C],
  output logic [N-1:0]   alloc_req,                 // slot needs an FP register
  output logic [N-1:0]   alloc_valid,               // ... and got one
  output preg_t          dest_preg [N],
  output preg_t          src1_preg [N],
  output preg_t          src2_preg [N],
  output preg_t          src3_preg [N],
  output preg_t          old_dest_preg [N]
);

  localparam int NR = 4 * N;
  localparam int TW = FP_PTR_W;
  localparam int RW = FP_ARF_NUM * TW;
  typedef logic [FP_ARF_NUM-1:0][TW-1:0] ent_t;

  logic [N-2:0] producer;
  areg_t        dest_areg [N], look_areg [N][4];
  areg_t        rd_areg [NR];
  preg_t        rd_preg [NR];
  preg_t        look_rat [N][4], look_preg [N][4];
  preg_t        window [N], alloc_reg [N];
  fp_ptr_t      free_count, head, head_after [N], head_next, head_last, ckpt_wr_head, ckpt_head;
  logic         any_fire;
  ent_t         ckpt_wr_rat, ckpt_rat;
  logic [FP_ARF_NUM-1:0][PRF_IDX_WIDTH-1:0] spec_rat;
  logic [CW-1:0] free_rank [C];
  logic [CW-1:0] free_total;
  logic [RW-1:0] ckpt_wr_rat_flat, ckpt_rat_flat;

  // walk muxed RAT / free-list inputs
  logic [N-1:0] rat_alloc_cand, rat_fire, walk_fp_alloc;
  areg_t        rat_alloc_areg [N];
  preg_t        rat_alloc_preg [N];
  logic [$clog2(N+1)-1:0] walk_fp_cnt;

  // an FP-destination slot (f0 included: the decoder keeps dest_en for it)
  for (genvar i = 0; i < N; i++) begin : g_view
    assign dest_areg[i]        = inst[i].dest_areg;
    assign alloc_req[i]        = inst_valid[i] & inst[i].dest_en & inst[i].dest_fp;
    assign look_areg[i][0]     = inst[i].src1_areg;
    assign look_areg[i][1]     = inst[i].src2_areg;
    assign look_areg[i][2]     = inst[i].src3_areg;
    assign look_areg[i][3]     = inst[i].dest_areg;
    for (genvar q = 0; q < 4; q++) begin : g_q
      assign rd_areg[q*N+i]    = look_areg[i][q];
      assign look_rat[i][q]    = rd_preg[q*N+i];
    end

    assign walk_fp_alloc[i]    = walk_slot_en[i] & walk_entry[i].dest_en & walk_entry[i].dest_fp;
    assign rat_alloc_cand[i]   = walk_active ? walk_fp_alloc[i] : alloc_req[i];
    assign rat_fire[i]         = walk_active ? walk_slot_en[i]  : fire[i];
    assign rat_alloc_areg[i]   = walk_active ? walk_entry[i].dest_areg : dest_areg[i];
    assign rat_alloc_preg[i]   = walk_active ? walk_entry[i].dest_preg : alloc_reg[i];
  end
  for (genvar i = 0; i < N - 1; i++) begin : g_prod
    assign producer[i] = alloc_req[i];
  end

  ttg_popcount #(.N(N)) u_walk_fp_pc (.bits(walk_fp_alloc), .count(walk_fp_cnt));

  logic [FP_ARF_NUM-1:0] fp_rd_oh_zero [NR];
  logic [FP_ARF_NUM-1:0] fp_wr_oh_zero [N];
  always_comb begin
    for (int r = 0; r < NR; r++) fp_rd_oh_zero[r] = '0;
    for (int i = 0; i < N;  i++) fp_wr_oh_zero[i] = '0;
  end

  ren_rat #(.NR(NR), .ENTRIES(FP_ARF_NUM), .FP(1'b1)) u_rat (
    .clk(clk), .rst_n(rst_n), .rd_areg(rd_areg), .rd_oh_in(fp_rd_oh_zero), .rd_preg(rd_preg),
    .alloc_cand(rat_alloc_cand), .fire(rat_fire), .alloc_areg(rat_alloc_areg),
    .wr_oh_in(fp_wr_oh_zero), .use_wr_oh(1'b0), .alloc_preg(rat_alloc_preg),
    .ckpt_wr_lane_oh(ckpt_wr_lane_oh),
    .reclaim(reclaim), .commit_areg(c_dest_areg), .commit_preg(c_dest_preg),
    .flush(rob_flush), .mispred(dec_mispred), .ckpt_hit(ckpt_rd_hit), .ckpt_rat(ckpt_rat),
    .ckpt_wr_rat(ckpt_wr_rat), .spec_rat(spec_rat)
  );

  ren_alloc_sel u_alloc (
    .req(alloc_req), .window(window), .free_count(preg_t'(free_count)), .alloc_valid(alloc_valid),
    .alloc_reg(alloc_reg)
  );

  ren_fp_dep u_dep (
    .producer(producer), .dest_areg(dest_areg), .look_areg(look_areg), .alloc_reg(alloc_reg),
    .look_rat(look_rat), .look_preg(look_preg)
  );

  for (genvar i = 0; i < N; i++) begin : g_out
    assign dest_preg[i]     = alloc_reg[i];
    assign src1_preg[i]     = look_preg[i][0];
    assign src2_preg[i]     = look_preg[i][1];
    assign src3_preg[i]     = look_preg[i][2];
    assign old_dest_preg[i] = look_preg[i][3];
  end

  // ---- commit side ----
  ren_rank u_free_rank (.sel(reclaim), .rank(free_rank), .total(free_total));

  ren_last_write #(.N(N), .W(FP_PTR_W)) u_head_next (
    .hit(fire), .data(head_after), .any(any_fire), .value(head_last)
  );
  assign head_next = walk_active ? fp_ptr_add(head, fp_ptr_t'(walk_fp_cnt)) : (any_fire ? head_last : head);

  ren_fp_free_list u_fl (
    .clk(clk), .rst_n(rst_n), .head_next(head_next), .reclaim(reclaim), .reclaim_rank(free_rank),
    .reclaim_total(free_total), .reclaim_preg(c_old_dest_preg), .flush(rob_flush), .mispred(dec_mispred),
    .ckpt_hit(ckpt_rd_hit), .ckpt_head(ckpt_head), .window(window), .free_count(free_count), .head(head)
  );

  // ---- branch checkpoints: head after slot i = head + number of allocating requests in slots 0..i ----
  for (genvar i = 0; i < N; i++) begin : g_head_after
    logic [$clog2(N+1)-1:0] taken;
    ttg_popcount #(.N(N)) u_cnt (.bits(alloc_req & ({N{1'b1}} >> (N - 1 - i))), .count(taken));
    assign head_after[i] = fp_ptr_add(head, fp_ptr_t'(taken));
  end

  ttg_onehot_mux #(.N(N), .W(FP_PTR_W)) u_ckpt_head_sel (
    .sel(ckpt_wr_lane_oh), .data(head_after), .out(ckpt_wr_head)
  );
  assign ckpt_wr_rat_flat = ckpt_wr_rat;

  ren_ckpt #(.RW(RW), .HW(FP_PTR_W)) u_ckpt (
    .clk(clk), .rst_n(rst_n),
    .wr_en(ckpt_wr_en), .wr_slot(ckpt_wr_slot),
    .wr_rat(ckpt_wr_rat_flat), .wr_head(ckpt_wr_head),
    .rd_slot(ckpt_rd_slot), .rd_rat(ckpt_rat_flat), .rd_head(ckpt_head)
  );

  assign ckpt_rat = ent_t'(ckpt_rat_flat);

  // waiver: the spec RAT view is not needed here
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_spec;
  assign unused_spec = ^spec_rat;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
