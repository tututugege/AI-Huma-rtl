// Ref: back-end/Ren.cpp  class Ren  (F/D rename state: fp_spec_RAT, fp_arch_RAT, fp_free_list, fp_RAT_checkpoint)
`default_nettype none

// FP rename domain: the second RAT / free list / branch checkpoints of the rename stage. Instantiated by ren_core only
// when the core has an FP register file (FPRF_NUM > 0). The slot handshake (stall on an empty list, in order) stays in
// ren_core; this module only reports which FP-destination slots were served.
module ren_fp
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [N-1:0]  inst_valid,
  input  ren_inst_t     inst [N],
  input  logic [N-1:0]  fire,
  input  logic          dec_mispred,
  input  br_tag_t       dec_br_id,
  input  logic          rob_flush,
  input  logic [C-1:0]  reclaim,                   // commit slot retires an FP destination
  input  areg_t         c_dest_areg [C],
  input  preg_t         c_dest_preg [C],
  input  preg_t         c_old_dest_preg [C],
  output logic [N-1:0]  alloc_req,                 // slot needs an FP register
  output logic [N-1:0]  alloc_valid,               // ... and got one
  output preg_t         dest_preg [N],
  output preg_t         src1_preg [N],
  output preg_t         src2_preg [N],
  output preg_t         src3_preg [N],
  output preg_t         old_dest_preg [N]
);

  localparam int NR = 4 * N;
  localparam int RW = FP_ARF_NUM * PRF_IDX_WIDTH;
  typedef logic [FP_ARF_NUM-1:0][PRF_IDX_WIDTH-1:0] ent_t;

  logic [N-1:0] alloc_fire, rat_fire, br_fire;
  logic [N-2:0] producer;
  areg_t        dest_areg [N], look_areg [N][4];
  areg_t        rd_areg [NR];
  preg_t        rd_preg [NR];
  preg_t        look_rat [N][4], look_preg [N][4];
  preg_t        window [N], alloc_reg [N];
  fp_ptr_t      free_count, head, head_after [N], ckpt_head;
  ent_t         snapshot [N], ckpt_rat, spec_rat;
  br_tag_t      br_id [N];
  logic [CW-1:0] free_rank [C];
  logic [CW-1:0] free_total;
  logic [RW-1:0] snapshot_flat [N], ckpt_rat_flat;
  preg_t        ckpt_head_wide, head_after_wide [N];

  // an FP-destination slot (f0 included: the decoder keeps dest_en for it)
  for (genvar i = 0; i < N; i++) begin : g_view
    assign dest_areg[i]        = inst[i].dest_areg;
    assign br_id[i]            = inst[i].br_id;
    assign alloc_req[i]        = inst_valid[i] & inst[i].dest_en & inst[i].dest_fp;
    assign rat_fire[i]         = fire[i] & inst[i].dest_en & inst[i].dest_fp;
    assign alloc_fire[i]       = rat_fire[i];
    assign br_fire[i]          = fire[i] & ((inst[i].inst_type == ITYPE_BR) | (inst[i].inst_type == ITYPE_JALR));
    assign look_areg[i][0]     = inst[i].src1_areg;
    assign look_areg[i][1]     = inst[i].src2_areg;
    assign look_areg[i][2]     = inst[i].src3_areg;
    assign look_areg[i][3]     = inst[i].dest_areg;
    for (genvar q = 0; q < 4; q++) begin : g_q
      assign rd_areg[q*N+i]    = look_areg[i][q];
      assign look_rat[i][q]    = rd_preg[q*N+i];
    end
    assign snapshot_flat[i]    = snapshot[i];
    assign head_after_wide[i]  = preg_t'(head_after[i]);
  end
  for (genvar i = 0; i < N - 1; i++) begin : g_prod
    assign producer[i] = alloc_req[i];
  end

  ren_rat #(.NR(NR), .ENTRIES(FP_ARF_NUM), .FP(1'b1)) u_rat (
    .clk(clk), .rst_n(rst_n), .rd_areg(rd_areg), .rd_preg(rd_preg),
    .alloc_fire(rat_fire), .alloc_areg(dest_areg), .alloc_preg(alloc_reg),
    .reclaim(reclaim), .commit_areg(c_dest_areg), .commit_preg(c_dest_preg),
    .flush(rob_flush), .mispred(dec_mispred), .ckpt_rat(ckpt_rat), .snapshot(snapshot), .spec_rat(spec_rat)
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

  ren_fp_free_list u_fl (
    .clk(clk), .rst_n(rst_n), .alloc_fire(alloc_fire), .reclaim(reclaim), .reclaim_rank(free_rank),
    .reclaim_total(free_total), .reclaim_preg(c_old_dest_preg), .flush(rob_flush), .mispred(dec_mispred),
    .ckpt_head(ckpt_head), .window(window), .free_count(free_count), .head(head)
  );

  // ---- branch checkpoints: head after slot i = head + number of allocating fires in slots 0..i ----
  for (genvar i = 0; i < N; i++) begin : g_head_after
    logic [$clog2(N+1)-1:0] taken;
    ttg_popcount #(.N(N)) u_cnt (.bits(alloc_fire & ({N{1'b1}} >> (N - 1 - i))), .count(taken));
    assign head_after[i] = fp_ptr_add(head, fp_ptr_t'(taken));
  end

  ren_ckpt #(.RW(RW)) u_ckpt (
    .clk(clk), .rst_n(rst_n), .wr_valid(br_fire), .wr_br_id(br_id), .wr_rat(snapshot_flat),
    .wr_head(head_after_wide), .rd_br_id(dec_br_id), .rd_rat(ckpt_rat_flat), .rd_head(ckpt_head_wide)
  );

  assign ckpt_rat  = ent_t'(ckpt_rat_flat);
  assign ckpt_head = fp_ptr_t'(ckpt_head_wide);

  // waiver: the spec RAT view and the head pointer's upper bits are not needed here
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_spec;
  assign unused_spec = (^spec_rat) ^ (^ckpt_head_wide[PRF_IDX_WIDTH-1:FP_PTR_W]);
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
