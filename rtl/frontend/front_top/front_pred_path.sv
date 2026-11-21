// Ref: front-end/front_top.cpp  BPU -> PTAB -> head_fix -> predecode_checker -> front2back_FIFO + output bypass
`default_nettype none

module front_pred_path import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import bpu_types_pkg::FTB_BLK_ID_W; (
  input  logic                clk,
  input  logic                rst_n,
  // control (front_ctrl)
  input  logic                global_refetch,
  input  logic [XLEN_BITS-1:0] refetch_address,
  input  logic                be_refetch,
  input  logic                be_fifo_read_enable,
  input  logic                bpu_icache_read_ready,
  input  logic                ptab_wr_en,
  input  logic                predecode_can_run,
  input  logic                f2b_wr_en,
  input  logic                f2b_use_bypass,
  input  logic                refetch_pd,
  // repair information of a back-end branch mispredict (uses internal BPU rec_q[256])
  input  logic                rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] rf_blk,
  input  logic [2:0]          rf_type,
  input  logic [XLEN_BITS-1:0] rf_pc,
  input  logic                rf_is_rvc,
  // commit-time update of the BPU
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0] base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  upd_is_rvc,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0] target     [NCOMMIT],
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [NCOMMIT-1:0]  alt_pred,
  input  logic [front_pkg::PCPN_W-1:0] pcpn [NCOMMIT],
  input  logic [FTB_BLK_ID_W-1:0] blk_id    [NCOMMIT],
  // instruction queue head
  input  inst_fifo_entry_t    inst_rd,
  // to control / fetch / icache FDIP
  output logic                bpu_icache_read_valid,
  output logic [XLEN_BITS-1:0] bpu_fetch_address,
  output fetch_pair_t         bpu_fetch_pair,
  output logic                bpu_ptab_write_enable,
  output logic                bpu_override_squash,
  output logic                fdip_s2_en,
  output logic [XLEN_BITS-1:0] fdip_s2_va,
  output logic                fdip_s2_clear,
  output logic                ptab_empty,
  output logic                f2b_full,
  output logic                f2b_empty,
  output logic                checker_flush_enable,
  output logic [XLEN_BITS-1:0] checker_flush_address,
  // front.out
  output logic [FETCH_WIDTH-1:0] out_inst_valid,
  output logic [31:0]         out_instructions    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] out_pf_inst_hi,
  output logic [FETCH_WIDTH-1:0] out_predict_dir,
  output logic [XLEN_BITS-1:0] out_pc              [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_alt_pred,
  output logic [front_pkg::PCPN_W-1:0] out_pcpn   [FETCH_WIDTH],
  output logic [BLK_ID_W-1:0] out_blk_id,
  output logic                out_is_pair,
  output logic [3:0]          out_a_len,
  output logic [XLEN_BITS-1:0] out_predict_next_fetch_address,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] out_slot_kind,
  output logic [FETCH_WIDTH-1:0] out_is_rvc,
  output logic [3:0]          commit_upd_free,
  output logic [3:0]          commit_tq_free
);

  // ---- BPU ----
  logic [XLEN_BITS-1:0]   bpu_predict_next_fetch_address, bpu_ptab_base_pc, bpu_ptab_base_b;
  logic                   bpu_ptab_is_pair, bpu_override_valid;
  logic [3:0]             bpu_ptab_a_len;
  logic                   bpu_pair_valid;
  logic [XLEN_BITS-1:0]   bpu_pair_addr2;
  logic [3:0]             bpu_pair_a_len, bpu_pair_b_len;
  logic [FETCH_WIDTH-1:0] bpu_pred_dir, bpu_alt_pred;
  logic [front_pkg::PCPN_W-1:0] bpu_pcpn [FETCH_WIDTH];
  logic [FTB_BLK_ID_W-1:0] bpu_blk_id;

  logic [7:0] ptab_size8;
  logic [$clog2(PTAB_DEPTH + 1)-1:0] ptab_size;
  logic                 pd_valid, pd_flush, pd_nb_valid;
  logic [1:0]           pd_hn, pd_ras_op, pd_ras_op2;
  logic [5:0]           pd_hbits;
  logic [XLEN_BITS-1:0] pd_ras_val, pd_ras_val2, pd_nb_pc, pd_nb_base;

  assign ptab_size8     = 8'(ptab_size);
  assign bpu_fetch_pair = '{valid: bpu_pair_valid, addr2: bpu_pair_addr2, a_len: bpu_pair_a_len, b_len: bpu_pair_b_len};
  assign fdip_s2_en     = bpu_ptab_write_enable;
  assign fdip_s2_va     = bpu_predict_next_fetch_address;
  assign fdip_s2_clear  = global_refetch || bpu_override_valid;

  bpu u_bpu (
    .clk, .rst_n,
    .refetch                    (global_refetch),
    .refetch_address,
    .refetch_pd,
    .icache_read_ready          (bpu_icache_read_ready),
    .ptab_size                  (ptab_size8),
    .rf_valid, .rf_blk, .rf_type, .rf_pc, .rf_is_rvc,
    .pd_valid, .pd_flush, .pd_hn, .pd_hbits, .pd_ras_op, .pd_ras_val, .pd_ras_op2, .pd_ras_val2,
    .pd_nb_valid, .pd_nb_pc, .pd_nb_base,
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .blk_id,
    .icache_read_valid          (bpu_icache_read_valid),
    .fetch_address              (bpu_fetch_address),
    .pair_valid                 (bpu_pair_valid),
    .pair_addr2                 (bpu_pair_addr2),
    .pair_a_len                 (bpu_pair_a_len),
    .pair_b_len                 (bpu_pair_b_len),
    .override_valid             (bpu_override_valid),
    .override_squash            (bpu_override_squash),
    .ptab_write_enable          (bpu_ptab_write_enable),
    .ptab_base_pc               (bpu_ptab_base_pc),
    .ptab_is_pair               (bpu_ptab_is_pair),
    .ptab_base_b                (bpu_ptab_base_b),
    .ptab_a_len                 (bpu_ptab_a_len),
    .predict_next_fetch_address (bpu_predict_next_fetch_address),
    .out_pred_dir               (bpu_pred_dir),
    .out_alt_pred               (bpu_alt_pred),
    .out_pcpn                   (bpu_pcpn),
    .out_blk_id                 (bpu_blk_id),
    .commit_upd_free, .commit_tq_free
  );

  // ---- PTAB ----
  logic [XLEN_BITS-1:0]   ptab_rd_predict_next_fetch_address, ptab_rd_predict_base_pc, ptab_rd_base_b;
  logic                   ptab_rd_is_pair;
  logic [3:0]             ptab_rd_a_len;
  logic [FETCH_WIDTH-1:0] ptab_rd_predict_dir, ptab_rd_alt_pred;
  logic [front_pkg::PCPN_W-1:0] ptab_rd_pcpn [FETCH_WIDTH];
  logic [BLK_ID_W-1:0]    ptab_rd_blk_id;

  /* verilator lint_off UNUSEDSIGNAL */
  logic ptab_rd_valid, ptab_full_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  ptab u_ptab (
    .clk, .rst_n,
    .refetch                       (global_refetch),
    .rd_en                         (predecode_can_run),
    .wr_en                         (ptab_wr_en),
    .wr_predict_next_fetch_address (bpu_predict_next_fetch_address),
    .wr_predict_dir                (bpu_pred_dir),
    .wr_predict_base_pc            (bpu_ptab_base_pc),
    .wr_is_pair                    (bpu_ptab_is_pair),
    .wr_base_b                     (bpu_ptab_base_b),
    .wr_a_len                      (bpu_ptab_a_len),
    .wr_alt_pred                   (bpu_alt_pred),
    .wr_pcpn                       (bpu_pcpn),
    .wr_blk_id                     (bpu_blk_id),
    .rd_valid                      (ptab_rd_valid),
    .rd_predict_next_fetch_address (ptab_rd_predict_next_fetch_address),
    .rd_predict_dir                (ptab_rd_predict_dir),
    .rd_predict_base_pc            (ptab_rd_predict_base_pc),
    .rd_is_pair                    (ptab_rd_is_pair),
    .rd_base_b                     (ptab_rd_base_b),
    .rd_a_len                      (ptab_rd_a_len),
    .rd_alt_pred                   (ptab_rd_alt_pred),
    .rd_pcpn                       (ptab_rd_pcpn),
    .rd_blk_id                     (ptab_rd_blk_id),
    .full                          (ptab_full_unused),
    .empty                         (ptab_empty),
    .size                          (ptab_size)
  );

  // ---- Head fix (A/B mux + PTAB PC cut + RVC carry/straddler) ----
  logic                   lh_valid_q;
  logic [XLEN_BITS-1:0]   lh_pc_q;
  logic [15:0]            lh_data_q;
  logic [31:0]            hf_insts   [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] hf_valid, hf_pf, hf_pf_hi, hf_rvc, hf_in_range, hf_seg_first;
  logic [1:0]             hf_type    [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   hf_target  [FETCH_WIDTH], hf_slot_pc [FETCH_WIDTH], hf_ptab_pc [FETCH_WIDTH];
  logic                   hf_multi, hf_carry, hf_straddle;
  logic [XLEN_BITS-1:0]   hf_end, hf_seq_next;
  logic [15:0]            hf_low;

  front_head_fix u_head_fix (
    .inst_e       (inst_rd),
    .ptab_base_pc (ptab_rd_predict_base_pc),
    .ptab_is_pair (ptab_rd_is_pair),
    .ptab_base_b  (ptab_rd_base_b),
    .ptab_a_len   (ptab_rd_a_len),
    .predict_dir  (ptab_rd_predict_dir),
    .lh_valid     (lh_valid_q),
    .lh_pc        (lh_pc_q),
    .lh_data      (lh_data_q),
    .insts_o      (hf_insts),
    .valid_o      (hf_valid),
    .pf_o         (hf_pf),
    .pf_hi_o      (hf_pf_hi),
    .ptype_o      (hf_type),
    .ptarget_o    (hf_target),
    .is_rvc_o     (hf_rvc),
    .slot_pc_o    (hf_slot_pc),
    .ptab_pc_o    (hf_ptab_pc),
    .multi_o      (hf_multi),
    .in_range_o   (hf_in_range),
    .seg_first_o  (hf_seg_first),
    .carry        (hf_carry),
    .straddle     (hf_straddle),
    .carry_low    (hf_low),
    .group_end_pc (hf_end),
    .seq_next_o   (hf_seq_next)
  );

  // ---- Predecode checker ----
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
  logic [FETCH_WIDTH-1:0]             checker_dir_corrected, f2b_wr_valid_kept;
  logic [XLEN_BITS-1:0]               checker_next_corrected;
  logic [4:0]                         checker_keep_n;

  predecode_checker u_checker (
    .clk, .rst_n,
    .multi                                (hf_multi),
    .in_range                             (hf_in_range),
    .seg_first                            (hf_seg_first),
    .slot_pc                              (hf_slot_pc),
    .inst_valid                           (hf_valid),
    .is_rvc                               (hf_rvc),
    .predict_dir                          (ptab_rd_predict_dir),
    .predict_next_fetch_address           (ptab_rd_predict_next_fetch_address),
    .predecode_type                       (hf_type),
    .predecode_target_address             (hf_target),
    .seq_next_pc                          (hf_seq_next),
    .predict_dir_corrected                (checker_dir_corrected),
    .predict_next_fetch_address_corrected (checker_next_corrected),
    .predecode_flush_enable               (checker_flush_enable),
    .keep_n                               (checker_keep_n)
  );
  assign checker_flush_address = checker_next_corrected;

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_kind
    front_slot_kind u_kind (.inst(hf_insts[i]), .kind(slot_kind[i]));
    assign f2b_wr_valid_kept[i] = hf_valid[i] && (5'(i) < checker_keep_n);
  end

  front_pd_info u_pd (
    .clk, .rst_n, .checked(predecode_can_run), .flush(predecode_can_run && checker_flush_enable),
    .multi(hf_multi), .keep_n(checker_keep_n), .seg_first(hf_seg_first),
    .slot_pc(hf_slot_pc), .ptab_pc(hf_ptab_pc), .is_rvc(hf_rvc), .insts(hf_insts), .inst_valid(hf_valid),
    .ptype(hf_type), .pre_target(hf_target),
    .dir_corrected(checker_dir_corrected), .predict_dir(ptab_rd_predict_dir),
    .ptab_next(ptab_rd_predict_next_fetch_address),
    .pd_valid, .pd_flush, .pd_hn, .pd_hbits, .pd_ras_op, .pd_ras_val, .pd_ras_op2, .pd_ras_val2,
    .pd_nb_valid, .pd_nb_pc, .pd_nb_base
  );

  // RVC carry state (only last segment's taken branches inhibit sequential continuation)
  logic [XLEN_BITS-1:0] lh_new_pc;
  logic                 lh_new_valid, any_taken_last;
  always_comb begin
    logic [3:0] last_seg;
    last_seg       = 4'd0;
    any_taken_last = 1'b0;
    for (int i = 0; i < FETCH_WIDTH; i++) if (hf_seg_first[i]) last_seg = 4'(i);
    for (int i = 0; i < FETCH_WIDTH; i++)
      if ((4'(i) >= last_seg) && hf_valid[i] && checker_dir_corrected[i]) any_taken_last = 1'b1;
    lh_new_pc    = hf_end;
    lh_new_valid = hf_straddle && !any_taken_last &&
                   (!checker_flush_enable || (checker_next_corrected == lh_new_pc));
  end

  always_ff @(posedge clk) begin
    if (!rst_n || be_refetch)   lh_valid_q <= 1'b0;
    else if (predecode_can_run) lh_valid_q <= lh_new_valid;
    if (predecode_can_run) begin
      lh_pc_q   <= lh_new_pc;
      lh_data_q <= hf_low;
    end
  end

  // ---- front2back queue ----
  logic [31:0]            f2b_rd_fetch_group [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] f2b_rd_page_fault_inst, f2b_rd_pf_inst_hi, f2b_rd_inst_valid, f2b_rd_predict_dir_corrected;
  logic [XLEN_BITS-1:0]   f2b_rd_predict_base_pc, f2b_rd_base_b, f2b_rd_predict_next_fetch_address_corrected;
  logic                   f2b_rd_is_pair, f2b_rd_carry;
  logic [3:0]             f2b_rd_a_len;
  logic [FETCH_WIDTH-1:0] f2b_rd_alt_pred, f2b_rd_is_rvc;
  logic [front_pkg::PCPN_W-1:0] f2b_rd_pcpn [FETCH_WIDTH];
  logic [BLK_ID_W-1:0]    f2b_rd_blk_id;
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] f2b_rd_kind;

  /* verilator lint_off UNUSEDSIGNAL */
  logic f2b_rd_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  front2back_fifo u_f2b_fifo (
    .clk, .rst_n,
    .refetch                                 (be_refetch),
    .rd_en                                   (be_fifo_read_enable),
    .wr_en                                   (f2b_wr_en),
    .wr_fetch_group                          (hf_insts),
    .wr_page_fault_inst                      (hf_pf),
    .wr_pf_inst_hi                           (hf_pf_hi),
    .wr_inst_valid                           (f2b_wr_valid_kept),
    .wr_predict_dir_corrected                (checker_dir_corrected),
    .wr_predict_base_pc                      (ptab_rd_predict_base_pc),
    .wr_is_pair                              (ptab_rd_is_pair),
    .wr_base_b                               (ptab_rd_base_b),
    .wr_a_len                                (ptab_rd_a_len),
    .wr_alt_pred                             (ptab_rd_alt_pred),
    .wr_pcpn                                 (ptab_rd_pcpn),
    .wr_blk_id                               (ptab_rd_blk_id),
    .wr_predict_next_fetch_address_corrected (checker_next_corrected),
    .wr_slot_kind                            (slot_kind),
    .wr_is_rvc                               (hf_rvc),
    .wr_carry                                (hf_carry),
    .rd_valid                                (f2b_rd_valid),
    .rd_fetch_group                          (f2b_rd_fetch_group),
    .rd_page_fault_inst                      (f2b_rd_page_fault_inst),
    .rd_pf_inst_hi                           (f2b_rd_pf_inst_hi),
    .rd_inst_valid                           (f2b_rd_inst_valid),
    .rd_predict_dir_corrected                (f2b_rd_predict_dir_corrected),
    .rd_predict_base_pc                      (f2b_rd_predict_base_pc),
    .rd_is_pair                              (f2b_rd_is_pair),
    .rd_base_b                               (f2b_rd_base_b),
    .rd_a_len                                (f2b_rd_a_len),
    .rd_alt_pred                             (f2b_rd_alt_pred),
    .rd_pcpn                                 (f2b_rd_pcpn),
    .rd_blk_id                               (f2b_rd_blk_id),
    .rd_predict_next_fetch_address_corrected (f2b_rd_predict_next_fetch_address_corrected),
    .rd_slot_kind                            (f2b_rd_kind),
    .rd_is_rvc                               (f2b_rd_is_rvc),
    .rd_carry                                (f2b_rd_carry),
    .full                                    (f2b_full),
    .empty                                   (f2b_empty)
  );

  // ---- front.out ----
  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      out_inst_valid[i]      = f2b_use_bypass ? f2b_wr_valid_kept[i] : f2b_rd_inst_valid[i];
      out_instructions[i]    = f2b_use_bypass ? hf_insts[i]          : f2b_rd_fetch_group[i];
      out_is_rvc[i]          = f2b_use_bypass ? hf_rvc[i]            : f2b_rd_is_rvc[i];
      out_page_fault_inst[i] = f2b_use_bypass ? hf_pf[i]             : f2b_rd_page_fault_inst[i];
      out_pf_inst_hi[i]      = f2b_use_bypass ? hf_pf_hi[i]          : f2b_rd_pf_inst_hi[i];
      out_predict_dir[i]     = f2b_use_bypass ? checker_dir_corrected[i] : f2b_rd_predict_dir_corrected[i];
      out_alt_pred[i]        = f2b_use_bypass ? ptab_rd_alt_pred[i]  : f2b_rd_alt_pred[i];
      out_pcpn[i]            = f2b_use_bypass ? ptab_rd_pcpn[i]      : f2b_rd_pcpn[i];
      out_pc[i] = f2b_use_bypass
                  ? hf_ptab_pc[i]
                  : pair_slot_pc(f2b_rd_predict_base_pc, f2b_rd_is_pair, f2b_rd_a_len, f2b_rd_base_b, i);
    end
    out_blk_id  = f2b_use_bypass ? ptab_rd_blk_id  : f2b_rd_blk_id;
    out_is_pair = f2b_use_bypass ? ptab_rd_is_pair : f2b_rd_is_pair;
    out_a_len   = f2b_use_bypass ? ptab_rd_a_len   : f2b_rd_a_len;
    out_pc[0] = f2b_use_bypass ? hf_ptab_pc[0]
                               : (f2b_rd_carry ? (f2b_rd_predict_base_pc - XLEN_BITS'(SLOT_BYTES))
                                               : f2b_rd_predict_base_pc);
    out_predict_next_fetch_address = f2b_use_bypass ? checker_next_corrected
                                                    : f2b_rd_predict_next_fetch_address_corrected;
    out_slot_kind = f2b_use_bypass ? slot_kind : f2b_rd_kind;
  end

endmodule

`default_nettype wire
