// Ref: front-end/front_top.cpp  BPU + Unified FTQ-64 S2/PD path (no PTAB, no ptab_bypass, no front2back_fifo)
`default_nettype none

module front_pred_path import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import bpu_types_pkg::FTB_BLK_ID_W; (
  input  logic                clk,
  input  logic                rst_n,
  // control (front_ctrl)
  input  logic                global_refetch,
  input  logic [XLEN_BITS-1:0] refetch_address,
  input  logic                be_refetch,
  input  logic                bpu_icache_read_ready,
  input  logic                s2_wr_en,
  input  logic                predecode_can_run,
  input  logic                refetch_pd,
  // Unified FTQ-64 registered pd_ptr prediction view (from ftq_ibuf)
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_pd_idx,
  input  logic [XLEN_BITS-1:0]     ftq_pd_base_pc,
  input  logic                     ftq_pd_is_pair,
  input  logic [XLEN_BITS-1:0]     ftq_pd_base_b,
  input  logic [3:0]               ftq_pd_a_len,
  input  logic [FETCH_WIDTH-1:0]   ftq_pd_pred_dir,
  input  logic [XLEN_BITS-1:0]     ftq_pd_next_pc,
  // repair information of a back-end branch mispredict (uses internal BPU rec_q[256])
  input  logic                rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] rf_blk,
  input  logic [FTB_BLK_ID_W-1:0] next_rf_blk,
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
  output logic                checker_flush_enable,
  output logic [XLEN_BITS-1:0] checker_flush_address,
  // Unified FTQ-64 S2 and PD write bundles
  output fe_ftq_s2_t          fe2ftq_s2,
  output fe_ftq_pd_t          fe2ftq_pd,
  // front.out -> core_front2back (trimmed: instructions + ftq_idx only)
  output logic [FETCH_WIDTH-1:0] out_lane_valid,
  output logic [31:0]         out_instructions    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] out_pf_inst_hi,
  output logic [FTQ_IDX_WIDTH-1:0] out_ftq_idx,
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

  logic                 pd_valid, pd_flush, pd_nb_valid;
  logic [1:0]           pd_hn, pd_ras_op, pd_ras_op2;
  logic [5:0]           pd_hbits;
  logic [XLEN_BITS-1:0] pd_ras_val, pd_ras_val2, pd_nb_pc, pd_nb_base;

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
    .rf_valid, .rf_blk, .next_rf_blk, .rf_type, .rf_pc, .rf_is_rvc,
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

  // ---- S2 write request to Unified FTQ-64 (registered next cycle; no ptab_bypass!) ----
  always_comb begin
    fe2ftq_s2          = '0;
    fe2ftq_s2.wr_en    = s2_wr_en;
    fe2ftq_s2.base_pc  = bpu_ptab_base_pc;
    fe2ftq_s2.is_pair  = bpu_ptab_is_pair;
    fe2ftq_s2.base_b   = bpu_ptab_base_b;
    fe2ftq_s2.a_len    = bpu_ptab_a_len;
    fe2ftq_s2.pred_dir = bpu_pred_dir;
    fe2ftq_s2.next_pc  = bpu_predict_next_fetch_address;
    fe2ftq_s2.alt_pred = bpu_alt_pred;
    for (int i = 0; i < FETCH_WIDTH; i++) fe2ftq_s2.pcpn[i] = bpu_pcpn[i];
    fe2ftq_s2.blk_id   = bpu_blk_id;
  end

  // ---- Head fix (A/B mux + FTQ pd_ptr PC cut + RVC carry/straddler) ----
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
    .ptab_base_pc (ftq_pd_base_pc),
    .ptab_is_pair (ftq_pd_is_pair),
    .ptab_base_b  (ftq_pd_base_b),
    .ptab_a_len   (ftq_pd_a_len),
    .predict_dir  (ftq_pd_pred_dir),
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
  logic [FETCH_WIDTH-1:0]             checker_dir_corrected, pd_raw_valid, pd_cut_valid;
  logic [XLEN_BITS-1:0]               checker_next_corrected;
  logic [4:0]                         checker_keep_n, pd_nslots;

  predecode_checker u_checker (
    .clk, .rst_n,
    .multi                                (hf_multi),
    .in_range                             (hf_in_range),
    .seg_first                            (hf_seg_first),
    .slot_pc                              (hf_slot_pc),
    .inst_valid                           (hf_valid),
    .is_rvc                               (hf_rvc),
    .predict_dir                          (ftq_pd_pred_dir),
    .predict_next_fetch_address           (ftq_pd_next_pc),
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
    assign pd_raw_valid[i] = hf_valid[i] && (5'(i) < checker_keep_n);
  end

  // Cut after predicted-taken lane (resetting on 2-taken PC discontinuity), matching FrontControl::finish
  always_comb begin
    logic no_taken;
    no_taken  = 1'b1;
    pd_nslots = 5'd0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if ((i > 0) && !no_taken && pd_raw_valid[i - 1] && pd_raw_valid[i] &&
          (hf_ptab_pc[i] != (hf_ptab_pc[i - 1] + (hf_rvc[i - 1] ? XLEN_BITS'(2) : XLEN_BITS'(4)))) &&
          checker_dir_corrected[i - 1])
        no_taken = 1'b1;
      pd_cut_valid[i] = no_taken && pd_raw_valid[i];
      if (pd_cut_valid[i] && checker_dir_corrected[i]) no_taken = 1'b0;
      if (pd_cut_valid[i]) pd_nslots = 5'(i + 1);
    end
  end

  front_pd_info u_pd (
    .clk, .rst_n, .checked(predecode_can_run), .flush(predecode_can_run && checker_flush_enable),
    .multi(hf_multi), .keep_n(checker_keep_n), .seg_first(hf_seg_first),
    .slot_pc(hf_slot_pc), .ptab_pc(hf_ptab_pc), .is_rvc(hf_rvc), .insts(hf_insts), .inst_valid(hf_valid),
    .ptype(hf_type), .pre_target(hf_target),
    .dir_corrected(checker_dir_corrected), .predict_dir(ftq_pd_pred_dir),
    .ptab_next(ftq_pd_next_pc),
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

  // ---- Unified FTQ-64 PD write request + direct delivery to core_front2back ----
  always_comb begin
    fe2ftq_pd           = '0;
    fe2ftq_pd.fire      = predecode_can_run;
    fe2ftq_pd.flush     = predecode_can_run && checker_flush_enable;
    fe2ftq_pd.empty_blk = !(|pd_cut_valid);
    fe2ftq_pd.carry     = hf_carry;
    fe2ftq_pd.pc0       = hf_ptab_pc[0];
    fe2ftq_pd.pred_dir  = pd_cut_valid & checker_dir_corrected;
    fe2ftq_pd.is_rvc    = hf_rvc;
    fe2ftq_pd.next_pc   = checker_next_corrected;
    fe2ftq_pd.nslots    = pd_nslots;
    fe2ftq_pd.slot_kind = slot_kind;

    out_lane_valid      = predecode_can_run ? pd_cut_valid : '0;
    out_instructions    = hf_insts;
    out_page_fault_inst = hf_pf;
    out_pf_inst_hi      = hf_pf_hi;
    out_ftq_idx         = ftq_pd_idx;
  end

endmodule

`default_nettype wire
