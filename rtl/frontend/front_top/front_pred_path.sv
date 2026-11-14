// Ref: front-end/front_top.cpp  front_comb_calc S4 (BPU), S9 (PTAB write), S10 (checker), S11/S14 (front2back write,
//      output bypass, front.out)
`default_nettype none

// Prediction side of the front end: BPU -> PTAB, the predecode checker that compares the PTAB head with the predecoded
// instruction-queue head, and the front2back queue with its same-cycle output bypass.
//   front.out of a cycle = the front2back queue head, or (queue empty, back end reading, a group passing the checker)
//   the entry that is being written this very cycle (bypass).  Lane i pc = lane-0 pc + 4*i (constructive, see ptab.sv).
// SC-L / loop predictor metadata is constant 0 in this configuration (BPU has no such outputs): zero on the PTAB side.
module front_pred_path import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // control (front_ctrl)
  input  logic                global_refetch,
  input  logic [XLEN_BITS-1:0]         refetch_address,
  input  logic                be_refetch,
  input  logic                be_fifo_read_enable,
  input  logic                bpu_icache_read_ready,
  input  logic                ptab_wr_en,
  input  logic                predecode_can_run,
  input  logic                f2b_wr_en,
  input  logic                f2b_use_bypass,
  input  logic                refetch_pd,
  // repair information of a back-end branch mispredict (registered back2front)
  input  logic                rf_valid,
  input  logic [HCK_W-1:0]    rf_ck,
  input  logic [EPOCH_W-1:0]  rf_epoch,
  input  logic [2:0]          rf_type,
  input  logic [XLEN_BITS-1:0]         rf_pc,
  // commit-time update of the BPU (registered back2front)
  input  logic [NCOMMIT-1:0] upd_valid,
  input  logic [XLEN_BITS-1:0]         base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0] actual_dir,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0]         target     [NCOMMIT],
  input  logic [NCOMMIT-1:0] pred_dir,
  input  logic [NCOMMIT-1:0] alt_pred,
  input  logic [front_pkg::PCPN_W-1:0]   pcpn       [NCOMMIT],
  input  logic [T_TAG_W-1:0]  tags       [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs       [NCOMMIT][TN],
  // instruction queue head (predecoded group)
  input  logic [31:0]         inst_rd_instructions             [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] inst_rd_page_fault_inst,
  input  logic [FETCH_WIDTH-1:0] inst_rd_inst_valid,
  input  logic [1:0]          inst_rd_predecode_type           [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]         inst_rd_predecode_target_address [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]         inst_rd_seq_next_pc,
  input  logic [15:0]         inst_rd_raw0,
  input  logic [FETCH_WIDTH-1:0] inst_rd_is_rvc,
  input  logic [FETCH_WIDTH-1:0] inst_rd_start_a,
  input  logic [FETCH_WIDTH-1:0] inst_rd_start_b,
  // to control / fetch side
  output logic                bpu_icache_read_valid,
  output logic [XLEN_BITS-1:0]         bpu_fetch_address,
  output logic                bpu_ptab_write_enable,
  output logic                bpu_override_valid,
  output logic                bpu_override_squash,
  output logic                ptab_empty,
  output logic                f2b_full,
  output logic                f2b_empty,
  output logic                checker_flush_enable,
  output logic [XLEN_BITS-1:0]         checker_flush_address,
  // front.out (valid / per-lane valid are made by the top: out_valid & out_inst_valid)
  output logic [FETCH_WIDTH-1:0] out_inst_valid,
  output logic [31:0]         out_instructions    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] out_predict_dir,
  output logic [XLEN_BITS-1:0]         out_pc              [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_alt_pred,
  output logic [front_pkg::PCPN_W-1:0]   out_pcpn            [FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0] out_tage_idx      [FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0] out_tage_tag      [FETCH_WIDTH][TN_MAX],
  output logic [XLEN_BITS-1:0]         out_predict_next_fetch_address,
  output logic [BCK_W-1:0]    out_bpu_ck,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] out_slot_kind,
  output logic [FETCH_WIDTH-1:0] out_is_rvc,
  output logic [3:0] commit_upd_free,   // compact ROB commit credits (EXP-028)
  output logic [3:0] commit_tq_free
);

  // ---- BPU ----
  logic [XLEN_BITS-1:0]         bpu_predict_next_fetch_address;
  logic [FETCH_WIDTH-1:0] bpu_pred_dir;
  logic [FETCH_WIDTH-1:0] bpu_alt_pred;
  logic [front_pkg::PCPN_W-1:0]   bpu_pcpn     [FETCH_WIDTH];
  logic [T_TAG_W-1:0]  bpu_tage_tags [FETCH_WIDTH][TN];
  logic [T_IDX_W-1:0]  bpu_tage_idxs [FETCH_WIDTH][TN];

  logic [XLEN_BITS-1:0]        bpu_ptab_base_pc;
  logic [BCK_W-1:0]   bpu_bck;
  logic [7:0]         ptab_size8;
  logic [$clog2(PTAB_DEPTH + 1)-1:0] ptab_size;
  logic               pd_valid, pd_flush, pd_hv;
  logic [HSYM_W-1:0]  pd_hbits;
  logic [1:0]         pd_ras_op;
  logic [XLEN_BITS-1:0]        pd_ras_val;
  logic [HCK_W-1:0]   bpu_out_ck;
  logic [EPOCH_W-1:0] bpu_out_epoch;

  assign ptab_size8 = 8'(ptab_size);
  assign bpu_bck    = {bpu_out_epoch, bpu_out_ck};

  bpu u_bpu (
    .clk, .rst_n,
    .refetch                    (global_refetch),
    .refetch_address,
    .refetch_pd,
    .icache_read_ready          (bpu_icache_read_ready),
    .ptab_size                  (ptab_size8),
    .rf_valid, .rf_ck, .rf_epoch, .rf_type, .rf_pc,
    .pd_valid, .pd_flush, .pd_hv, .pd_hbits, .pd_ras_op, .pd_ras_val,
    .upd_valid, .base_pc, .actual_dir, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .tags, .idxs,
    .icache_read_valid          (bpu_icache_read_valid),
    .fetch_address              (bpu_fetch_address),
    .override_valid             (bpu_override_valid),
    .override_squash            (bpu_override_squash),
    .ptab_write_enable          (bpu_ptab_write_enable),
    .ptab_base_pc               (bpu_ptab_base_pc),
    .predict_next_fetch_address (bpu_predict_next_fetch_address),
    .out_pred_dir               (bpu_pred_dir),
    .out_alt_pred               (bpu_alt_pred),
    .out_pcpn                   (bpu_pcpn),
    .out_tage_tags              (bpu_tage_tags),
    .out_tage_idxs              (bpu_tage_idxs),
    .out_ck                     (bpu_out_ck),
    .out_epoch                  (bpu_out_epoch),
    .commit_upd_free, .commit_tq_free
  );

  // ---- PTAB (written with the BPU prediction, read together with the instruction queue) ----
  logic [XLEN_BITS-1:0]         ptab_rd_predict_next_fetch_address;
  logic [FETCH_WIDTH-1:0] ptab_rd_predict_dir;
  logic [XLEN_BITS-1:0]         ptab_rd_predict_base_pc;
  logic [FETCH_WIDTH-1:0] ptab_rd_alt_pred;
  logic [front_pkg::PCPN_W-1:0]   ptab_rd_pcpn     [FETCH_WIDTH];
  logic [TAGE_IDX_W-1:0] ptab_rd_tage_idx [FETCH_WIDTH][TN_MAX];
  logic [TAGE_TAG_W-1:0] ptab_rd_tage_tag [FETCH_WIDTH][TN_MAX];
  logic [BCK_W-1:0]    ptab_rd_bck;

  // the fifo-valid flags are not consumed (valid = can_run)
  /* verilator lint_off UNUSEDSIGNAL */
  logic                ptab_rd_valid;
  logic                ptab_full_unused;   // the BPU credit replaces the full latch
  /* verilator lint_on UNUSEDSIGNAL */

  ptab u_ptab (
    .clk, .rst_n,
    .refetch                       (global_refetch),
    .rd_en                         (predecode_can_run),
    .wr_en                         (ptab_wr_en),
    .wr_predict_next_fetch_address (bpu_predict_next_fetch_address),
    .wr_predict_dir                (bpu_pred_dir),
    .wr_predict_base_pc            (bpu_ptab_base_pc),
    .wr_alt_pred                   (bpu_alt_pred),
    .wr_pcpn                       (bpu_pcpn),
    .wr_tage_idx                   (bpu_tage_idxs),
    .wr_tage_tag                   (bpu_tage_tags),
    .wr_bpu_ck                     (bpu_bck),
    .rd_valid                      (ptab_rd_valid),
    .rd_predict_next_fetch_address (ptab_rd_predict_next_fetch_address),
    .rd_predict_dir                (ptab_rd_predict_dir),
    .rd_predict_base_pc            (ptab_rd_predict_base_pc),
    .rd_alt_pred                   (ptab_rd_alt_pred),
    .rd_pcpn                       (ptab_rd_pcpn),
    .rd_tage_idx                   (ptab_rd_tage_idx),
    .rd_tage_tag                   (ptab_rd_tage_tag),
    .rd_bpu_ck                     (ptab_rd_bck),
    .full                          (ptab_full_unused),
    .empty                         (ptab_empty),
    .size                          (ptab_size)
  );

  // ---- RVC=1: carry register (first halfword of a 32-bit instruction that starts in the last slot of a group) ----
  logic                  lh_valid_q;
  logic [XLEN_BITS-1:0]  lh_pc_q;
  logic [15:0]           lh_data_q;
  logic [31:0]           hf_insts   [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] hf_valid;
  logic [1:0]            hf_type    [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]  hf_target  [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] hf_rvc;
  logic                  hf_carry, hf_straddle;
  logic [XLEN_BITS-1:0]  hf_pc0, hf_end;
  logic [15:0]           hf_low;

  front_head_fix u_head_fix (
    .base_pc(ptab_rd_predict_base_pc),
    .insts_i(inst_rd_instructions), .valid_i(inst_rd_inst_valid), .page_fault(inst_rd_page_fault_inst),
    .ptype_i(inst_rd_predecode_type), .ptarget_i(inst_rd_predecode_target_address),
    .is_rvc_i(inst_rd_is_rvc), .start_a(inst_rd_start_a), .start_b(inst_rd_start_b), .raw0(inst_rd_raw0),
    .lh_valid(lh_valid_q), .lh_pc(lh_pc_q), .lh_data(lh_data_q),
    .insts_o(hf_insts), .valid_o(hf_valid), .ptype_o(hf_type), .ptarget_o(hf_target), .is_rvc_o(hf_rvc),
    .carry(hf_carry), .pc0(hf_pc0), .straddle(hf_straddle), .carry_low(hf_low), .group_end_pc(hf_end)
  );

  // ---- predecode checker: PTAB head vs predecoded instruction-queue head ----
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
  logic [FETCH_WIDTH-1:0] checker_dir_corrected;
  logic [XLEN_BITS-1:0] checker_next_corrected;

  predecode_checker u_checker (
    .clk, .rst_n,
    .predict_dir                          (ptab_rd_predict_dir),
    .predict_next_fetch_address           (ptab_rd_predict_next_fetch_address),
    .predecode_type                       (hf_type),
    .predecode_target_address             (hf_target),
    .seq_next_pc                          (inst_rd_seq_next_pc),
    .predict_dir_corrected                (checker_dir_corrected),
    .predict_next_fetch_address_corrected (checker_next_corrected),
    .predecode_flush_enable               (checker_flush_enable)
  );
  assign checker_flush_address = checker_next_corrected;

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_kind
    front_slot_kind u_kind (.inst(hf_insts[i]), .kind(slot_kind[i]));
  end

  front_pd_info u_pd (
    .clk, .rst_n, .checked(predecode_can_run), .flush(predecode_can_run && checker_flush_enable),
    .base_pc(ptab_rd_predict_base_pc), .pc0(hf_pc0), .is_rvc(hf_rvc), .insts(hf_insts), .inst_valid(hf_valid),
    .ptype(hf_type), .pre_target(hf_target),
    .dir_corrected(checker_dir_corrected), .ptab_next(ptab_rd_predict_next_fetch_address),
    .pd_valid, .pd_flush, .pd_hv, .pd_hbits, .pd_ras_op, .pd_ras_val
  );

  // the carry state follows the group the checker looks at (predecode_can_run); a back-end redirect drops it
  logic [XLEN_BITS-1:0] lh_new_pc;
  logic                 lh_new_valid, any_taken;
  assign lh_new_pc    = hf_end;
  assign any_taken    = |(hf_valid & checker_dir_corrected);
  assign lh_new_valid = hf_straddle && !any_taken && (!checker_flush_enable || checker_next_corrected == lh_new_pc);
  always_ff @(posedge clk) begin
    if (!rst_n || be_refetch) lh_valid_q <= 1'b0;
    else if (predecode_can_run) lh_valid_q <= lh_new_valid;
    if (predecode_can_run) begin
      lh_pc_q   <= lh_new_pc;
      lh_data_q <= hf_low;
    end
  end

  // ---- front2back queue: write = checked group, read = what the back end sees next ----
  logic [31:0] f2b_rd_fetch_group [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] f2b_rd_page_fault_inst;
  logic [FETCH_WIDTH-1:0] f2b_rd_inst_valid;
  logic [FETCH_WIDTH-1:0] f2b_rd_predict_dir_corrected;
  logic [XLEN_BITS-1:0] f2b_rd_predict_base_pc;
  logic [FETCH_WIDTH-1:0] f2b_rd_alt_pred;
  logic [front_pkg::PCPN_W-1:0] f2b_rd_pcpn [FETCH_WIDTH];
  logic [TAGE_IDX_W-1:0] f2b_rd_tage_idx [FETCH_WIDTH][TN_MAX];
  logic [TAGE_TAG_W-1:0] f2b_rd_tage_tag [FETCH_WIDTH][TN_MAX];
  logic [XLEN_BITS-1:0] f2b_rd_predict_next_fetch_address_corrected;
  logic [BCK_W-1:0] f2b_rd_bck;
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] f2b_rd_kind;
  logic [FETCH_WIDTH-1:0] f2b_rd_is_rvc;
  logic                   f2b_rd_carry;

  /* verilator lint_off UNUSEDSIGNAL */
  logic                f2b_rd_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  front2back_fifo u_f2b_fifo (
    .clk, .rst_n,
    .refetch                                 (be_refetch),
    .rd_en                                   (be_fifo_read_enable),
    .wr_en                                   (f2b_wr_en),
    .wr_fetch_group                          (hf_insts),
    .wr_page_fault_inst                      (inst_rd_page_fault_inst),
    .wr_inst_valid                           (hf_valid),
    .wr_predict_dir_corrected                (checker_dir_corrected),
    .wr_predict_base_pc                      (ptab_rd_predict_base_pc),
    .wr_alt_pred                             (ptab_rd_alt_pred),
    .wr_pcpn                                 (ptab_rd_pcpn),
    .wr_tage_idx                             (ptab_rd_tage_idx),
    .wr_tage_tag                             (ptab_rd_tage_tag),
    .wr_predict_next_fetch_address_corrected (checker_next_corrected),
    .wr_bpu_ck                               (ptab_rd_bck),
    .wr_slot_kind                            (slot_kind),
    .wr_is_rvc                               (hf_rvc),
    .wr_carry                                (hf_carry),
    .rd_valid                                (f2b_rd_valid),
    .rd_fetch_group                          (f2b_rd_fetch_group),
    .rd_page_fault_inst                      (f2b_rd_page_fault_inst),
    .rd_inst_valid                           (f2b_rd_inst_valid),
    .rd_predict_dir_corrected                (f2b_rd_predict_dir_corrected),
    .rd_predict_base_pc                      (f2b_rd_predict_base_pc),
    .rd_alt_pred                             (f2b_rd_alt_pred),
    .rd_pcpn                                 (f2b_rd_pcpn),
    .rd_tage_idx                             (f2b_rd_tage_idx),
    .rd_tage_tag                             (f2b_rd_tage_tag),
    .rd_predict_next_fetch_address_corrected (f2b_rd_predict_next_fetch_address_corrected),
    .rd_bpu_ck                               (f2b_rd_bck),
    .rd_slot_kind                            (f2b_rd_kind),
    .rd_is_rvc                               (f2b_rd_is_rvc),
    .rd_carry                                (f2b_rd_carry),
    .full                                    (f2b_full),
    .empty                                   (f2b_empty)
  );

  // ---- front.out: queue head, or the entry being written when the bypass is taken (queue empty => no head) ----
  logic [XLEN_BITS-1:0] out_base_pc;
  always_comb begin
    out_base_pc = f2b_use_bypass ? ptab_rd_predict_base_pc : f2b_rd_predict_base_pc;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      out_inst_valid[i]      = f2b_use_bypass ? hf_valid[i]                : f2b_rd_inst_valid[i];
      out_instructions[i]    = f2b_use_bypass ? hf_insts[i]                : f2b_rd_fetch_group[i];
      out_is_rvc[i]          = f2b_use_bypass ? hf_rvc[i]                  : f2b_rd_is_rvc[i];
      out_page_fault_inst[i] = f2b_use_bypass ? inst_rd_page_fault_inst[i] : f2b_rd_page_fault_inst[i];
      out_predict_dir[i]     = f2b_use_bypass ? checker_dir_corrected[i]   : f2b_rd_predict_dir_corrected[i];
      out_alt_pred[i]        = f2b_use_bypass ? ptab_rd_alt_pred[i]        : f2b_rd_alt_pred[i];
      out_pcpn[i]            = f2b_use_bypass ? ptab_rd_pcpn[i]            : f2b_rd_pcpn[i];
      for (int j = 0; j < TN_MAX; j++) begin
        out_tage_idx[i][j] = f2b_use_bypass ? ptab_rd_tage_idx[i][j] : f2b_rd_tage_idx[i][j];
        out_tage_tag[i][j] = f2b_use_bypass ? ptab_rd_tage_tag[i][j] : f2b_rd_tage_tag[i][j];
      end
      out_pc[i] = out_base_pc + XLEN_BITS'(SLOT_BYTES * i);
    end
    // a carried slot 0 starts one slot before the group
    out_pc[0] = f2b_use_bypass ? hf_pc0 : (f2b_rd_carry ? out_base_pc - XLEN_BITS'(SLOT_BYTES) : out_base_pc);
    out_predict_next_fetch_address = f2b_use_bypass ? checker_next_corrected
                                                    : f2b_rd_predict_next_fetch_address_corrected;
    out_bpu_ck    = f2b_use_bypass ? ptab_rd_bck : f2b_rd_bck;
    out_slot_kind = f2b_use_bypass ? slot_kind   : f2b_rd_kind;
  end

endmodule

`default_nettype wire
