// Ref: back-end/Ren.cpp  class Ren  (comb_alloc / comb_rename / comb_fire / seq + local RenLog + K-ckpt + 8-wide walk)
`default_nettype none

// Rename stage: pipeline register -> free-list allocation -> RAT lookup + same-group bypass -> Dispatch;
// on fire the RAT/free list/local RenLog advance and sparse branches checkpoint; commit reads local RenLog;
// mispredict restores sparse checkpoint (or arch RAT) and runs 8-wide forward walk via RenLog.
module ren_core
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int NK = REN_CKPT_NUM,
  parameter int KW = (NK > 1) ? $clog2(NK) : 1,
  parameter int CW = $clog2(C + 1)
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // dec2ren
  input  logic [N-1:0]             dec_valid,
  input  ren_inst_t                dec_uop [N],
  // dec_bcast / rob_bcast / dis2ren
  input  logic                     dec_mispred,
  input  logic [ROB_IDX_WIDTH-1:0] dec_redirect_rob_idx,
  input  logic                     dis_ready,
  input  logic                     rob_flush,
  input  logic                     rob_interrupt,
  // rob_commit (only valid/exception/type; rename fields live in local ren_log)
  input  ren_commit_t              commit [C],
  // ren2dec / ren2dis / ren2rob
  output logic                     ren2dec_ready,
  output logic                     ren2rob_walking,
  output logic [N-1:0]             ren2dis_valid,
  output ren_out_uop_t             ren2dis_uop [N],
  // commit-side dest_preg from local ren_log (for soc_tb difftest probe)
  output preg_t                    commit_dest_preg [C]
);

  localparam int NR = 3 * N;
  localparam int INT_TW = $clog2(PRF_NUM);
  typedef logic [RAT_NUM-1:0][INT_TW-1:0] int_rat_t;

  logic [N-1:0] inst_valid, alloc_req, alloc_valid, fire, rat_cand, is_branch;
  logic [N-1:0] fp_alloc_req, fp_alloc_valid;   // F/D: slots that need / got an FP register (own free list)
  logic [N-1:0] req_all, valid_all;             // both domains, for the in-order stall chain
  logic [N-1:0] elim;                           // move elimination: renamed away, takes no free register
  logic [N-1:0] move_shape;
  ren_inst_t    inst [N];
  preg_t        window [N], alloc_reg [N], free_count, head;
  // rename
  areg_t        rd_areg [NR];
  preg_t        rd_preg [NR];
  preg_t        dest_normal [N], src1_normal [N], src2_normal [N];
  preg_t        old_dest_preg [N], src1_preg [N], src2_preg [N], dest_preg [N];
  areg_t        dest_areg [N];
  preg_t        fp_dest [N], fp_src1 [N], fp_src2 [N], fp_src3 [N], fp_old [N];
  int_rat_t     ckpt_wr_rat, ckpt_rat;
  // sparse checkpoint & local ren_log & walk
  logic                     walk_active;
  logic [N-1:0]             log_ok, walk_slot_en;
  logic [ROB_IDX_WIDTH-1:0] lane_rob_idx [N];
  logic [ROB_IDX_WIDTH-1:0] log_rd_base_next;
  logic                     ckpt_wr_en, ckpt_rd_hit;
  logic [KW-1:0]            ckpt_wr_slot, ckpt_rd_slot;
  logic [N-1:0]             ckpt_wr_lane_oh;
  ren_log_entry_t           log_wr_entry [N];
  ren_log_entry_t           log_rd_slot [N];
  preg_t        head_after [N], head_next, head_last;
  logic [INT_TW-1:0] head_after_lo [N], ckpt_wr_head, ckpt_head_lo;
  logic         any_fire;
  preg_t        ckpt_head;
  // walk muxed INT RAT / free-list inputs
  logic [N-1:0] rat_alloc_cand, rat_fire, walk_int_rat, walk_int_alloc;
  areg_t        rat_alloc_areg [N];
  preg_t        rat_alloc_preg [N];
  logic [$clog2(N+1)-1:0] walk_int_cnt;
  // commit
  logic [C-1:0] reclaim_all;      // every retiring destination (either domain)
  logic [C-1:0] reclaim;          // ... INT domain
  logic [C-1:0] c_fp;
  logic [CW-1:0] alloc_commit_total;
  logic [C-1:0] free;             // commit slot returns its old register to the free list
  logic [CW-1:0] free_rank [C];
  logic [CW-1:0] free_total;
  logic [C-1:0] c_elim;
  logic [C-1:0] c_valid, c_dest_en, c_pf_inst, c_pf_load, c_pf_store, c_illegal;
  logic [dis_pkg::INST_TYPE_W-1:0] c_type [C];
  areg_t        c_dest_areg [C];
  preg_t        c_dest_preg [C];
  preg_t        c_old_dest_preg [C];

  assign ren2rob_walking = walk_active;

  logic                s1_empty, s2_take_new;
  logic [RAT_NUM-1:0]  pipe_rd_oh_q [3*N];
  logic [RAT_NUM-1:0]  pipe_wr_oh_q [N];
  logic [N-1:0]        pipe_move_shape_q, pipe_is_branch_q;
  logic [N-1:0]        pipe_hit_dest_q [N], pipe_hit_src1_q [N], pipe_hit_src2_q [N];

  ren_inst_pipe u_pipe (
    .clk(clk), .rst_n(rst_n), .dec_valid(dec_valid), .dec_uop(dec_uop),
    .s1_take_new(ren2dec_ready), .s2_take_new(s2_take_new),
    .kill(rob_flush | dec_mispred), .fire(fire),
    .s1_empty(s1_empty), .valid(inst_valid), .inst(inst),
    .rd_oh_q(pipe_rd_oh_q), .wr_oh_q(pipe_wr_oh_q),
    .move_shape_q(pipe_move_shape_q), .is_branch_q(pipe_is_branch_q),
    .raw_hit_dest_q(pipe_hit_dest_q), .raw_hit_src1_q(pipe_hit_src1_q), .raw_hit_src2_q(pipe_hit_src2_q)
  );

  // ---- field views of the pipeline register / commit entries ----
  for (genvar i = 0; i < N; i++) begin : g_view
    assign dest_areg[i]  = inst[i].dest_areg;
    assign rd_areg[i]       = inst[i].dest_areg;
    assign rd_areg[N+i]     = inst[i].src1_areg;
    assign rd_areg[2*N+i]   = inst[i].src2_areg;
    assign dest_normal[i]   = rd_preg[i];
    assign src1_normal[i]   = rd_preg[N+i];
    assign src2_normal[i]   = rd_preg[2*N+i];
    assign move_shape[i]    = pipe_move_shape_q[i];
    assign alloc_req[i]     = inst_valid[i] & inst[i].dest_en & ~inst[i].dest_fp & ~elim[i];
    assign rat_cand[i]      = inst_valid[i] & inst[i].dest_en & ~inst[i].dest_fp;
    assign is_branch[i]     = pipe_is_branch_q[i];

    assign log_wr_entry[i] = '{
      dest_en:       inst[i].dest_en,
      dest_fp:       inst[i].dest_fp,
      dest_areg:     inst[i].dest_areg,
      dest_preg:     inst[i].dest_fp ? fp_dest[i] : dest_preg[i],
      old_dest_preg: inst[i].dest_fp ? fp_old[i]  : old_dest_preg[i],
      me_elim:       elim[i]
    };

    assign walk_int_rat[i]   = walk_slot_en[i] & log_rd_slot[i].dest_en & ~log_rd_slot[i].dest_fp;
    assign walk_int_alloc[i] = walk_int_rat[i] & ~log_rd_slot[i].me_elim;
    assign rat_alloc_cand[i] = walk_active ? walk_int_rat[i]           : rat_cand[i];
    assign rat_fire[i]       = walk_active ? walk_slot_en[i]           : fire[i];
    assign rat_alloc_areg[i] = walk_active ? log_rd_slot[i].dest_areg  : dest_areg[i];
    assign rat_alloc_preg[i] = walk_active ? log_rd_slot[i].dest_preg  : dest_preg[i];
  end
  for (genvar k = 0; k < C; k++) begin : g_commit_view
    assign c_valid[k]          = commit[k].valid;
    assign c_pf_inst[k]        = commit[k].page_fault_inst;
    assign c_pf_load[k]        = commit[k].page_fault_load;
    assign c_pf_store[k]       = commit[k].page_fault_store;
    assign c_illegal[k]        = commit[k].illegal_inst;
    assign c_type[k]           = commit[k].inst_type;
    // rename fields come from local ren_log (1R1W: normal cycles read at ren_rob_head)
    assign c_dest_en[k]        = log_rd_slot[k].dest_en;
    assign c_elim[k]           = log_rd_slot[k].me_elim;
    assign c_fp[k]             = log_rd_slot[k].dest_fp;
    assign c_dest_areg[k]      = log_rd_slot[k].dest_areg;
    assign c_dest_preg[k]      = log_rd_slot[k].dest_preg;
    assign c_old_dest_preg[k]  = log_rd_slot[k].old_dest_preg;
    assign commit_dest_preg[k] = log_rd_slot[k].dest_preg;
  end

  // ---- sparse K-checkpoint & walk controller + local ROB-indexed RenLog ----
  ren_ckpt_ctl u_ckpt_ctl (
    .clk(clk), .rst_n(rst_n),
    .inst_valid(inst_valid), .fire(fire), .is_branch(is_branch),
    .commit_valid(c_valid), .flush(rob_flush), .mispred(dec_mispred),
    .dec_redirect_rob_idx(dec_redirect_rob_idx),
    .walk_active(walk_active), .log_ok(log_ok), .lane_rob_idx(lane_rob_idx),
    .rd_base_next(log_rd_base_next), .walk_slot_en(walk_slot_en),
    .ckpt_wr_en(ckpt_wr_en), .ckpt_wr_slot(ckpt_wr_slot), .ckpt_wr_lane_oh(ckpt_wr_lane_oh),
    .ckpt_rd_hit(ckpt_rd_hit), .ckpt_rd_slot(ckpt_rd_slot)
  );

  ren_log u_log (
    .clk(clk), .wr_valid(fire), .wr_rob_idx(lane_rob_idx), .wr_entry(log_wr_entry),
    .rd_base_next(log_rd_base_next), .rd_slot(log_rd_slot)
  );

  ttg_popcount #(.N(N)) u_walk_int_pc (.bits(walk_int_alloc), .count(walk_int_cnt));

  // ---- move elimination: which moves are renamed away (Ren::elim_refs_ok) ----
  ren_elim_sel u_elim (
    .inst_valid(inst_valid), .move_shape(move_shape), .raw_hit_src1(pipe_hit_src1_q), .elim(elim)
  );

  // ---- allocation (comb_alloc) ----
  ren_alloc_sel u_alloc (
    .req(alloc_req), .window(window), .free_count(free_count), .alloc_valid(alloc_valid), .alloc_reg(alloc_reg)
  );

  assign req_all   = alloc_req | fp_alloc_req;
  assign valid_all = alloc_valid | fp_alloc_valid;

  ren_handshake u_hs (
    .inst_valid(inst_valid), .alloc_req(req_all), .alloc_valid(valid_all),
    .log_ok(log_ok), .walk_active(walk_active), .s1_empty(s1_empty), .dis_ready(dis_ready),
    .flush(rob_flush), .mispred(dec_mispred), .out_valid(ren2dis_valid), .fire(fire),
    .s2_take_new(s2_take_new), .ren2dec_ready(ren2dec_ready)
  );

  // ---- rename (comb_rename) ----
  ren_dep_check u_dep (
    .inst_valid(inst_valid[N-2:0]),
    .raw_hit_dest(pipe_hit_dest_q), .raw_hit_src1(pipe_hit_src1_q), .raw_hit_src2(pipe_hit_src2_q),
    .alloc_reg(alloc_reg), .elim(elim), .dest_normal(dest_normal), .src1_normal(src1_normal), .src2_normal(src2_normal),
    .old_dest_preg(old_dest_preg), .src1_preg(src1_preg), .src2_preg(src2_preg), .dest_preg_out(dest_preg)
  );

  // ---- F/D domain ----
  logic [C-1:0] reclaim_fp;   // retiring FP destinations: ren_fp's arch RAT / free list
  assign reclaim_fp = reclaim_all & c_fp;
  ren_fp u_fp (
    .clk(clk), .rst_n(rst_n), .inst_valid(inst_valid), .inst(inst), .fire(fire),
    .dec_mispred(dec_mispred), .rob_flush(rob_flush),
    .ckpt_wr_en(ckpt_wr_en), .ckpt_wr_slot(ckpt_wr_slot), .ckpt_wr_lane_oh(ckpt_wr_lane_oh),
    .ckpt_rd_hit(ckpt_rd_hit), .ckpt_rd_slot(ckpt_rd_slot),
    .walk_active(walk_active), .walk_slot_en(walk_slot_en), .walk_entry(log_rd_slot),
    .reclaim(reclaim_fp), .c_dest_areg(c_dest_areg),
    .c_dest_preg(c_dest_preg), .c_old_dest_preg(c_old_dest_preg), .alloc_req(fp_alloc_req),
    .alloc_valid(fp_alloc_valid), .dest_preg(fp_dest), .src1_preg(fp_src1), .src2_preg(fp_src2),
    .src3_preg(fp_src3), .old_dest_preg(fp_old)
  );

  for (genvar i = 0; i < N; i++) begin : g_out
    assign ren2dis_uop[i] = '{diag_val: inst[i].diag_val, dest_areg: inst[i].dest_areg,
                              src1_areg: inst[i].src1_areg, ftq_idx: inst[i].ftq_idx,
                              ftq_offset: inst[i].ftq_offset, ftq_is_last: inst[i].ftq_is_last,
                              inst_type: inst[i].inst_type, dest_en: inst[i].dest_en, src1_en: inst[i].src1_en,
                              src2_en: inst[i].src2_en, is_atomic: inst[i].is_atomic,
                              src1_is_pc: inst[i].src1_is_pc, src2_is_imm: inst[i].src2_is_imm,
                              is_word: inst[i].is_word,
                              func3: inst[i].func3, func7: inst[i].func7, imm: inst[i].imm,
                              csr_idx: inst[i].csr_idx,
                              page_fault_inst: inst[i].page_fault_inst, pf_inst_hi: inst[i].pf_inst_hi,
                              illegal_inst: inst[i].illegal_inst,
                              dest_preg: inst[i].dest_fp ? fp_dest[i] : dest_preg[i],
                              src1_preg: inst[i].src1_fp ? fp_src1[i] : src1_preg[i],
                              src2_preg: inst[i].src2_fp ? fp_src2[i] : src2_preg[i],
                              me_elim: elim[i],
                              dest_fp: inst[i].dest_fp, src1_fp: inst[i].src1_fp, src2_fp: inst[i].src2_fp,
                              src3_en: inst[i].src3_en, src3_preg: fp_src3[i], fp_cls: inst[i].fp_cls};
  end

  // ---- commit side ----
  ren_commit_filter u_cf (
    .commit_valid(c_valid), .commit_dest_en(c_dest_en), .commit_page_fault_inst(c_pf_inst),
    .commit_page_fault_load(c_pf_load), .commit_page_fault_store(c_pf_store), .commit_illegal_inst(c_illegal),
    .commit_inst_type(c_type), .commit_elim(c_elim | c_fp), .rob_interrupt(rob_interrupt),
    .reclaim(reclaim_all), .alloc_total(alloc_commit_total)
  );
  // the FP domain has its own free list / arch RAT (ren_fp); alloc_total above counts INT registers only
  assign reclaim = reclaim_all & ~c_fp;

  // free-list returns (move elimination): a retiring destination frees its old register only when no architectural
  // RAT entry names the register any more
  ren_arch_cnt u_cnt (
    .clk(clk), .rst_n(rst_n), .reclaim(reclaim), .dest_preg(c_dest_preg), .old_preg(c_old_dest_preg),
    .free(free)
  );
  // 1-cycle pipelined INT free-list reclaim (decouples ren_arch_cnt from ren_free_list write)
  logic [C-1:0] free_q;
  preg_t        reclaim_preg_q [C];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      free_q <= '0;
    end else begin
      free_q         <= free;
      reclaim_preg_q <= c_old_dest_preg;
    end
  end
  ren_rank u_free_rank (.sel(free_q), .rank(free_rank), .total(free_total));

  ren_rat #(.PRE_OH(1'b1)) u_rat (
    .clk(clk), .rst_n(rst_n), .rd_areg(rd_areg), .rd_oh_in(pipe_rd_oh_q), .rd_preg(rd_preg),
    .alloc_cand(rat_alloc_cand), .fire(rat_fire), .alloc_areg(rat_alloc_areg),
    .wr_oh_in(pipe_wr_oh_q), .use_wr_oh(~walk_active), .alloc_preg(rat_alloc_preg),
    .ckpt_wr_en(ckpt_wr_en), .ckpt_wr_lane_oh(ckpt_wr_lane_oh),
    .reclaim(reclaim), .commit_areg(c_dest_areg), .commit_preg(c_dest_preg),
    .flush(rob_flush), .mispred(dec_mispred), .ckpt_hit(ckpt_rd_hit), .ckpt_rat(ckpt_rat),
    .ckpt_wr_rat(ckpt_wr_rat)
  );

  ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_head_next (
    .hit(fire), .data(head_after), .any(any_fire), .value(head_last)
  );
  assign head_next = walk_active ? ((head + preg_t'(walk_int_cnt)) & preg_t'(PRF_NUM - 1))
                                 : (any_fire ? head_last : head);

  ren_free_list u_fl (
    .clk(clk), .rst_n(rst_n), .head_next(head_next), .reclaim(free_q), .reclaim_rank(free_rank),
    .reclaim_total(free_total), .alloc_commit_total(alloc_commit_total), .reclaim_preg(reclaim_preg_q),
    .flush(rob_flush), .mispred(dec_mispred), .ckpt_hit(ckpt_rd_hit),
    .ckpt_head(ckpt_head), .window(window), .free_count(free_count), .head(head)
  );

  // ---- branch checkpoints: head after slot i = head + number of allocating requests in slots 0..i ----
  for (genvar i = 0; i < N; i++) begin : g_head_after
    logic [$clog2(N+1)-1:0] taken;
    ttg_popcount #(.N(N)) u_cnt (.bits(alloc_req & ({N{1'b1}} >> (N - 1 - i))), .count(taken));
    assign head_after[i]    = (head + preg_t'(taken)) & preg_t'(PRF_NUM - 1);   // ring position: wraps at PRF_NUM
    assign head_after_lo[i] = head_after[i][INT_TW-1:0];
  end

  ttg_onehot_mux #(.N(N), .W(INT_TW)) u_ckpt_head_sel (
    .sel(ckpt_wr_lane_oh), .data(head_after_lo), .out(ckpt_wr_head)
  );

  // 1-cycle pipelined checkpoint write (matches ren_rat's 1-cycle ckpt_wr_rat)
  logic             ckpt_wr_en_q;
  logic [KW-1:0]    ckpt_wr_slot_q;
  logic [INT_TW-1:0] ckpt_wr_head_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ckpt_wr_en_q <= 1'b0;
    end else begin
      ckpt_wr_en_q <= ckpt_wr_en;
      if (ckpt_wr_en) begin
        ckpt_wr_slot_q <= ckpt_wr_slot;
        ckpt_wr_head_q <= ckpt_wr_head;
      end
    end
  end

  ren_ckpt #(.RW(RAT_NUM * INT_TW), .HW(INT_TW)) u_ckpt (
    .clk(clk), .rst_n(rst_n),
    .wr_en(ckpt_wr_en_q), .wr_slot(ckpt_wr_slot_q),
    .wr_rat(ckpt_wr_rat), .wr_head(ckpt_wr_head_q),
    .rd_slot(ckpt_rd_slot), .rd_rat(ckpt_rat), .rd_head(ckpt_head_lo)
  );
  assign ckpt_head = preg_t'(ckpt_head_lo);

endmodule

`default_nettype wire
