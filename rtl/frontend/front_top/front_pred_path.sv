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
  input  logic [31:0]         refetch_address,
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
  input  logic [31:0]         rf_pc,
  // commit-time update of the BPU (registered back2front)
  input  logic [NCOMMIT-1:0] upd_valid,
  input  logic [31:0]         base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0] actual_dir,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [31:0]         target     [NCOMMIT],
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
  input  logic [31:0]         inst_rd_predecode_target_address [FETCH_WIDTH],
  input  logic [31:0]         inst_rd_seq_next_pc,
  // to control / fetch side
  output logic                bpu_icache_read_valid,
  output logic [31:0]         bpu_fetch_address,
  output logic                bpu_ptab_write_enable,
  output logic                bpu_override_valid,
  output logic                bpu_override_squash,
  output logic                ptab_empty,
  output logic                f2b_full,
  output logic                f2b_empty,
  output logic                checker_flush_enable,
  output logic [31:0]         checker_flush_address,
  // front.out (valid / per-lane valid are made by the top: out_valid & out_inst_valid)
  output logic [FETCH_WIDTH-1:0] out_inst_valid,
  output logic [31:0]         out_instructions    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] out_predict_dir,
  output logic [31:0]         out_pc              [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_alt_pred,
  output logic [front_pkg::PCPN_W-1:0]   out_altpcpn         [FETCH_WIDTH],
  output logic [front_pkg::PCPN_W-1:0]   out_pcpn            [FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0] out_tage_idx      [FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0] out_tage_tag      [FETCH_WIDTH][TN_MAX],
  output logic [31:0]         out_predict_next_fetch_address,
  output logic [BCK_W-1:0]    out_bpu_ck,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] out_slot_kind
);

  // ---- BPU ----
  logic [31:0]         bpu_predict_next_fetch_address;
  logic [FETCH_WIDTH-1:0] bpu_pred_dir;
  logic [FETCH_WIDTH-1:0] bpu_alt_pred;
  logic [front_pkg::PCPN_W-1:0]   bpu_pcpn     [FETCH_WIDTH];
  logic [front_pkg::PCPN_W-1:0]   bpu_altpcpn  [FETCH_WIDTH];
  logic [T_TAG_W-1:0]  bpu_tage_tags [FETCH_WIDTH][TN];
  logic [T_IDX_W-1:0]  bpu_tage_idxs [FETCH_WIDTH][TN];

  logic [31:0]        bpu_ptab_base_pc;
  logic [BCK_W-1:0]   bpu_bck;
  logic [7:0]         ptab_size8;
  logic [$clog2(PTAB_DEPTH + 1)-1:0] ptab_size;
  logic               pd_valid, pd_flush, pd_hv;
  logic [HSYM_W-1:0]  pd_hbits;
  logic [1:0]         pd_ras_op;
  logic [31:0]        pd_ras_val;
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
    .out_altpcpn                (bpu_altpcpn),
    .out_tage_tags              (bpu_tage_tags),
    .out_tage_idxs              (bpu_tage_idxs),
    .out_ck                     (bpu_out_ck),
    .out_epoch                  (bpu_out_epoch)
  );

  // ---- PTAB (written with the BPU prediction, read together with the instruction queue) ----
  logic [31:0]         ptab_rd_predict_next_fetch_address;
  logic [FETCH_WIDTH-1:0] ptab_rd_predict_dir;
  logic [31:0]         ptab_rd_predict_base_pc;
  logic [FETCH_WIDTH-1:0] ptab_rd_alt_pred;
  logic [front_pkg::PCPN_W-1:0]   ptab_rd_altpcpn  [FETCH_WIDTH];
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
    .wr_altpcpn                    (bpu_altpcpn),
    .wr_pcpn                       (bpu_pcpn),
    .wr_tage_idx                   (bpu_tage_idxs),
    .wr_tage_tag                   (bpu_tage_tags),
    .wr_bpu_ck                     (bpu_bck),
    .rd_valid                      (ptab_rd_valid),
    .rd_predict_next_fetch_address (ptab_rd_predict_next_fetch_address),
    .rd_predict_dir                (ptab_rd_predict_dir),
    .rd_predict_base_pc            (ptab_rd_predict_base_pc),
    .rd_alt_pred                   (ptab_rd_alt_pred),
    .rd_altpcpn                    (ptab_rd_altpcpn),
    .rd_pcpn                       (ptab_rd_pcpn),
    .rd_tage_idx                   (ptab_rd_tage_idx),
    .rd_tage_tag                   (ptab_rd_tage_tag),
    .rd_bpu_ck                     (ptab_rd_bck),
    .full                          (ptab_full_unused),
    .empty                         (ptab_empty),
    .size                          (ptab_size)
  );

  // ---- predecode checker: PTAB head vs predecoded instruction-queue head ----
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
  logic [FETCH_WIDTH-1:0] checker_dir_corrected;
  logic [31:0] checker_next_corrected;

  predecode_checker u_checker (
    .clk, .rst_n,
    .predict_dir                          (ptab_rd_predict_dir),
    .predict_next_fetch_address           (ptab_rd_predict_next_fetch_address),
    .predecode_type                       (inst_rd_predecode_type),
    .predecode_target_address             (inst_rd_predecode_target_address),
    .seq_next_pc                          (inst_rd_seq_next_pc),
    .predict_dir_corrected                (checker_dir_corrected),
    .predict_next_fetch_address_corrected (checker_next_corrected),
    .predecode_flush_enable               (checker_flush_enable)
  );
  assign checker_flush_address = checker_next_corrected;

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_kind
    front_slot_kind u_kind (.inst(inst_rd_instructions[i]), .kind(slot_kind[i]));
  end

  front_pd_info u_pd (
    .clk, .rst_n, .checked(predecode_can_run), .flush(predecode_can_run && checker_flush_enable),
    .base_pc(ptab_rd_predict_base_pc), .insts(inst_rd_instructions), .inst_valid(inst_rd_inst_valid),
    .ptype(inst_rd_predecode_type), .pre_target(inst_rd_predecode_target_address),
    .dir_corrected(checker_dir_corrected), .ptab_next(ptab_rd_predict_next_fetch_address),
    .pd_valid, .pd_flush, .pd_hv, .pd_hbits, .pd_ras_op, .pd_ras_val
  );

  // ---- front2back queue: write = checked group, read = what the back end sees next ----
  logic [31:0] f2b_rd_fetch_group [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] f2b_rd_page_fault_inst;
  logic [FETCH_WIDTH-1:0] f2b_rd_inst_valid;
  logic [FETCH_WIDTH-1:0] f2b_rd_predict_dir_corrected;
  logic [31:0] f2b_rd_predict_base_pc;
  logic [FETCH_WIDTH-1:0] f2b_rd_alt_pred;
  logic [front_pkg::PCPN_W-1:0] f2b_rd_altpcpn [FETCH_WIDTH];
  logic [front_pkg::PCPN_W-1:0] f2b_rd_pcpn [FETCH_WIDTH];
  logic [TAGE_IDX_W-1:0] f2b_rd_tage_idx [FETCH_WIDTH][TN_MAX];
  logic [TAGE_TAG_W-1:0] f2b_rd_tage_tag [FETCH_WIDTH][TN_MAX];
  logic [31:0] f2b_rd_predict_next_fetch_address_corrected;
  logic [BCK_W-1:0] f2b_rd_bck;
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] f2b_rd_kind;

  /* verilator lint_off UNUSEDSIGNAL */
  logic                f2b_rd_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  front2back_fifo u_f2b_fifo (
    .clk, .rst_n,
    .refetch                                 (be_refetch),
    .rd_en                                   (be_fifo_read_enable),
    .wr_en                                   (f2b_wr_en),
    .wr_fetch_group                          (inst_rd_instructions),
    .wr_page_fault_inst                      (inst_rd_page_fault_inst),
    .wr_inst_valid                           (inst_rd_inst_valid),
    .wr_predict_dir_corrected                (checker_dir_corrected),
    .wr_predict_base_pc                      (ptab_rd_predict_base_pc),
    .wr_alt_pred                             (ptab_rd_alt_pred),
    .wr_altpcpn                              (ptab_rd_altpcpn),
    .wr_pcpn                                 (ptab_rd_pcpn),
    .wr_tage_idx                             (ptab_rd_tage_idx),
    .wr_tage_tag                             (ptab_rd_tage_tag),
    .wr_predict_next_fetch_address_corrected (checker_next_corrected),
    .wr_bpu_ck                               (ptab_rd_bck),
    .wr_slot_kind                            (slot_kind),
    .rd_valid                                (f2b_rd_valid),
    .rd_fetch_group                          (f2b_rd_fetch_group),
    .rd_page_fault_inst                      (f2b_rd_page_fault_inst),
    .rd_inst_valid                           (f2b_rd_inst_valid),
    .rd_predict_dir_corrected                (f2b_rd_predict_dir_corrected),
    .rd_predict_base_pc                      (f2b_rd_predict_base_pc),
    .rd_alt_pred                             (f2b_rd_alt_pred),
    .rd_altpcpn                              (f2b_rd_altpcpn),
    .rd_pcpn                                 (f2b_rd_pcpn),
    .rd_tage_idx                             (f2b_rd_tage_idx),
    .rd_tage_tag                             (f2b_rd_tage_tag),
    .rd_predict_next_fetch_address_corrected (f2b_rd_predict_next_fetch_address_corrected),
    .rd_bpu_ck                               (f2b_rd_bck),
    .rd_slot_kind                            (f2b_rd_kind),
    .full                                    (f2b_full),
    .empty                                   (f2b_empty)
  );

  // ---- front.out: queue head, or the entry being written when the bypass is taken (queue empty => no head) ----
  logic [31:0] out_base_pc;
  always_comb begin
    out_base_pc = f2b_use_bypass ? ptab_rd_predict_base_pc : f2b_rd_predict_base_pc;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      out_inst_valid[i]      = f2b_use_bypass ? inst_rd_inst_valid[i]      : f2b_rd_inst_valid[i];
      out_instructions[i]    = f2b_use_bypass ? inst_rd_instructions[i]    : f2b_rd_fetch_group[i];
      out_page_fault_inst[i] = f2b_use_bypass ? inst_rd_page_fault_inst[i] : f2b_rd_page_fault_inst[i];
      out_predict_dir[i]     = f2b_use_bypass ? checker_dir_corrected[i]   : f2b_rd_predict_dir_corrected[i];
      out_alt_pred[i]        = f2b_use_bypass ? ptab_rd_alt_pred[i]        : f2b_rd_alt_pred[i];
      out_altpcpn[i]         = f2b_use_bypass ? ptab_rd_altpcpn[i]         : f2b_rd_altpcpn[i];
      out_pcpn[i]            = f2b_use_bypass ? ptab_rd_pcpn[i]            : f2b_rd_pcpn[i];
      for (int j = 0; j < TN_MAX; j++) begin
        out_tage_idx[i][j] = f2b_use_bypass ? ptab_rd_tage_idx[i][j] : f2b_rd_tage_idx[i][j];
        out_tage_tag[i][j] = f2b_use_bypass ? ptab_rd_tage_tag[i][j] : f2b_rd_tage_tag[i][j];
      end
      out_pc[i] = out_base_pc + 32'(4 * i);
    end
    out_predict_next_fetch_address = f2b_use_bypass ? checker_next_corrected
                                                    : f2b_rd_predict_next_fetch_address_corrected;
    out_bpu_ck    = f2b_use_bypass ? ptab_rd_bck : f2b_rd_bck;
    out_slot_kind = f2b_use_bypass ? slot_kind   : f2b_rd_kind;
  end

endmodule

`default_nettype wire
