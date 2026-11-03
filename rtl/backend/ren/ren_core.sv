// Ref: back-end/Ren.cpp  class Ren  (comb_alloc / comb_rename / comb_fire / comb_pipeline / seq)
`default_nettype none

// Rename stage: pipeline register -> free-list allocation -> RAT lookup + same-group bypass -> Dispatch;
// on fire the RAT/free list advance and branches checkpoint; commit/mispredict/flush restore.
module ren_core
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic          clk,
  input  logic          rst_n,
  // dec2ren
  input  logic [N-1:0]  dec_valid,
  input  ren_inst_t     dec_uop [N],
  // dec_bcast / rob_bcast / dis2ren
  input  logic          dec_mispred,
  input  br_tag_t       dec_br_id,
  input  br_mask_t      dec_clear_mask,
  input  logic          dis_ready,
  input  logic          rob_flush,
  input  logic          rob_interrupt,
  // rob_commit
  input  ren_commit_t   commit [C],
  // ren2dec / ren2dis
  output logic          ren2dec_ready,
  output logic [N-1:0]  ren2dis_valid,
  output ren_out_uop_t  ren2dis_uop [N]
);

  localparam int NR = 3 * N;

  logic [N-1:0] inst_valid, alloc_req, alloc_valid, fire, alloc_fire, br_fire;
  ren_inst_t    inst [N];
  preg_t        window [N], alloc_reg [N], free_count, head;
  // rename
  areg_t        rd_areg [NR];
  preg_t        rd_preg [NR];
  preg_t        dest_normal [N], src1_normal [N], src2_normal [N];
  preg_t        old_dest_preg [N], src1_preg [N], src2_preg [N];
  areg_t        dest_areg [N], src1_areg [N], src2_areg [N];
  logic [N-2:0] dest_en_older;    // dest_en of every slot except the youngest
  rat_t         snapshot [N];
  // checkpoint
  br_tag_t      br_id [N];
  preg_t        head_after [N];
  rat_t         ckpt_rat;
  preg_t        ckpt_head;
  // commit
  logic [C-1:0] reclaim;
  logic [CW-1:0] reclaim_rank [C];
  logic [CW-1:0] reclaim_total;
  logic [C-1:0] c_valid, c_dest_en, c_pf_inst, c_pf_load, c_pf_store, c_illegal;
  logic [INST_TYPE_WIDTH-1:0] c_type [C];
  areg_t        c_dest_areg [C];
  preg_t        c_dest_preg [C];
  preg_t        c_old_dest_preg [C];

  ren_inst_pipe u_pipe (
    .clk(clk), .rst_n(rst_n), .dec_valid(dec_valid), .dec_uop(dec_uop), .take_new(ren2dec_ready),
    .kill(rob_flush | dec_mispred), .fire(fire), .clear_mask(dec_clear_mask), .valid(inst_valid), .inst(inst)
  );

  // ---- field views of the pipeline register / commit entries ----
  for (genvar i = 0; i < N; i++) begin : g_view
    assign dest_areg[i]  = inst[i].dest_areg;
    assign src1_areg[i]  = inst[i].src1_areg;
    assign src2_areg[i]  = inst[i].src2_areg;
    assign br_id[i]      = inst[i].br_id;
    assign rd_areg[i]       = inst[i].dest_areg;
    assign rd_areg[N+i]     = inst[i].src1_areg;
    assign rd_areg[2*N+i]   = inst[i].src2_areg;
    assign dest_normal[i]   = rd_preg[i];
    assign src1_normal[i]   = rd_preg[N+i];
    assign src2_normal[i]   = rd_preg[2*N+i];
    assign alloc_req[i]     = inst_valid[i] & inst[i].dest_en;
    assign alloc_fire[i]    = fire[i] & inst[i].dest_en;
    assign br_fire[i]       = fire[i] & ((inst[i].inst_type == ITYPE_BR) | (inst[i].inst_type == ITYPE_JALR));
  end
  for (genvar i = 0; i < N - 1; i++) begin : g_older_view
    assign dest_en_older[i] = inst[i].dest_en;
  end
  for (genvar k = 0; k < C; k++) begin : g_commit_view
    assign c_valid[k]        = commit[k].valid;
    assign c_dest_en[k]      = commit[k].dest_en;
    assign c_pf_inst[k]      = commit[k].page_fault_inst;
    assign c_pf_load[k]      = commit[k].page_fault_load;
    assign c_pf_store[k]     = commit[k].page_fault_store;
    assign c_illegal[k]      = commit[k].illegal_inst;
    assign c_type[k]         = commit[k].inst_type;
    assign c_dest_areg[k]    = commit[k].dest_areg;
    assign c_dest_preg[k]    = commit[k].dest_preg;
    assign c_old_dest_preg[k] = commit[k].old_dest_preg;
  end

  // ---- allocation (comb_alloc) ----
  ren_alloc_sel u_alloc (
    .req(alloc_req), .window(window), .free_count(free_count), .alloc_valid(alloc_valid), .alloc_reg(alloc_reg)
  );

  ren_handshake u_hs (
    .inst_valid(inst_valid), .alloc_req(alloc_req), .alloc_valid(alloc_valid), .dis_ready(dis_ready),
    .flush(rob_flush), .mispred(dec_mispred), .out_valid(ren2dis_valid), .fire(fire), .ren2dec_ready(ren2dec_ready)
  );

  // ---- rename (comb_rename) ----
  ren_dep_check u_dep (
    .inst_valid(inst_valid[N-2:0]), .dest_en(dest_en_older), .dest_areg(dest_areg),
    .src1_areg(src1_areg), .src2_areg(src2_areg),
    .alloc_reg(alloc_reg), .dest_normal(dest_normal), .src1_normal(src1_normal), .src2_normal(src2_normal),
    .old_dest_preg(old_dest_preg), .src1_preg(src1_preg), .src2_preg(src2_preg)
  );

  for (genvar i = 0; i < N; i++) begin : g_out
    assign ren2dis_uop[i] = '{diag_val: inst[i].diag_val, dest_areg: inst[i].dest_areg,
                              src1_areg: inst[i].src1_areg, ftq_idx: inst[i].ftq_idx,
                              ftq_offset: inst[i].ftq_offset, ftq_is_last: inst[i].ftq_is_last,
                              inst_type: inst[i].inst_type, dest_en: inst[i].dest_en, src1_en: inst[i].src1_en,
                              src2_en: inst[i].src2_en, is_atomic: inst[i].is_atomic,
                              src1_is_pc: inst[i].src1_is_pc, src2_is_imm: inst[i].src2_is_imm,
                              func3: inst[i].func3, func7: inst[i].func7, imm: inst[i].imm, br_id: inst[i].br_id,
                              br_mask: inst[i].br_mask, csr_idx: inst[i].csr_idx,
                              page_fault_inst: inst[i].page_fault_inst, illegal_inst: inst[i].illegal_inst,
                              dest_preg: alloc_reg[i], src1_preg: src1_preg[i], src2_preg: src2_preg[i],
                              old_dest_preg: old_dest_preg[i]};
  end

  // ---- commit side ----
  ren_commit_filter u_cf (
    .commit_valid(c_valid), .commit_dest_en(c_dest_en), .commit_page_fault_inst(c_pf_inst),
    .commit_page_fault_load(c_pf_load), .commit_page_fault_store(c_pf_store), .commit_illegal_inst(c_illegal),
    .commit_inst_type(c_type), .rob_interrupt(rob_interrupt), .reclaim(reclaim), .rank(reclaim_rank),
    .total(reclaim_total)
  );

  ren_rat u_rat (
    .clk(clk), .rst_n(rst_n), .rd_areg(rd_areg), .rd_preg(rd_preg),
    .alloc_fire(alloc_fire), .alloc_areg(dest_areg), .alloc_preg(alloc_reg),
    .reclaim(reclaim), .commit_areg(c_dest_areg), .commit_preg(c_dest_preg),
    .flush(rob_flush), .mispred(dec_mispred), .ckpt_rat(ckpt_rat), .snapshot(snapshot)
  );

  ren_free_list u_fl (
    .clk(clk), .rst_n(rst_n), .alloc_fire(alloc_fire), .reclaim(reclaim), .reclaim_rank(reclaim_rank),
    .reclaim_total(reclaim_total), .reclaim_preg(c_old_dest_preg), .flush(rob_flush), .mispred(dec_mispred),
    .ckpt_head(ckpt_head), .window(window), .free_count(free_count), .head(head)
  );

  // ---- branch checkpoints: head after slot i = head + number of allocating fires in slots 0..i ----
  for (genvar i = 0; i < N; i++) begin : g_head_after
    logic [$clog2(N+1)-1:0] taken;
    ttg_popcount #(.N(N)) u_cnt (.bits(alloc_fire & ({N{1'b1}} >> (N - 1 - i))), .count(taken));
    assign head_after[i] = head + preg_t'(taken);
  end

  ren_ckpt u_ckpt (
    .clk(clk), .rst_n(rst_n), .wr_valid(br_fire), .wr_br_id(br_id), .wr_rat(snapshot), .wr_head(head_after),
    .rd_br_id(dec_br_id), .rd_rat(ckpt_rat), .rd_head(ckpt_head)
  );

endmodule

`default_nettype wire
