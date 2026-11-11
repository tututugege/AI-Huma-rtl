// Ref: rv_simu_mmu_v2.cpp  SimCpu::back2front_comb / FrontTop::seq_back2front (front.back2front register)
`default_nettype none

// The register between the back end and the front end: what the back end decided at the end of cycle t (redirect,
// fence flushes, the stall flag and the commit-time training data of the BPU) is seen by the front end in cycle t+1.
//   refetch       = back.out.mispred (already includes the ROB flush)       refetch_address = back.out.redirect_pc
//   itlb_flush    = rob_bcast.fence, fence_i = rob_bcast.fence_i            stall           = back.out.stall
//   update lane i = the i-th commit slot: type-derived actual direction / target / branch class + FTQ prediction info
// The C++ keeps the update fields of an invalid commit slot at their previous value; every consumer (BPU update queue,
// history, type predictor) is gated by upd_valid, so invalid slots are zeroed here instead (no hold registers).
module core_back2front import ttg_cfg_pkg::*; import dis_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  // back end outputs (cycle t)
  input  logic        out_mispred,
  input  logic        out_stall,
  input  logic [31:0] out_redirect_pc,
  input  logic        out_rf_valid,
  input  logic [HCK_W-1:0] out_rf_ck,
  input  logic [EPOCH_W-1:0] out_rf_epoch,
  input  logic [2:0]  out_rf_type,
  input  logic [31:0] out_rf_pc,
  input  logic        rob_bcast_fence,
  input  logic        rob_bcast_fence_i,
  input  logic [COMMIT_WIDTH-1:0] commit_valid,
  input  logic [4:0]  commit_type        [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] commit_br_taken,
  input  logic [COMMIT_WIDTH-1:0] commit_dest_en,
  input  logic [5:0]  commit_dest_areg   [COMMIT_WIDTH],
  input  logic [31:0] commit_diag_val    [COMMIT_WIDTH],
  input  logic [31:0] commit_imm         [COMMIT_WIDTH],
  input  logic [5:0]  commit_src1_areg   [COMMIT_WIDTH],
  input  logic [31:0] ftq_pc             [COMMIT_WIDTH],
  input  logic        ftq_pred_taken     [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] ftq_alt_pred,
  input  logic [2:0]  ftq_pcpn           [COMMIT_WIDTH],
  input  logic [9:0]  ftq_tage_idx       [COMMIT_WIDTH][TN],
  input  logic [7:0]  ftq_tage_tag       [COMMIT_WIDTH][TN],
  // registered: front end inputs (cycle t+1)
  output logic        refetch_q,
  output logic [31:0] refetch_address_q,
  output logic        rf_valid_q,
  output logic [HCK_W-1:0] rf_ck_q,
  output logic [EPOCH_W-1:0] rf_epoch_q,
  output logic [2:0]  rf_type_q,
  output logic [31:0] rf_pc_q,
  output logic        itlb_flush_q,
  output logic        fence_i_q,
  output logic        stall_q,
  output logic [COMMIT_WIDTH-1:0] upd_valid_q,
  output logic [31:0] upd_base_pc_q [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] upd_actual_dir_q,
  output logic [2:0]  upd_br_type_q [COMMIT_WIDTH],
  output logic [31:0] upd_target_q [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] upd_pred_dir_q,
  output logic [COMMIT_WIDTH-1:0] upd_alt_pred_q,
  output logic [2:0]  upd_pcpn_q [COMMIT_WIDTH],
  output logic [7:0]  upd_tags_q [COMMIT_WIDTH][TN],
  output logic [9:0]  upd_idxs_q [COMMIT_WIDTH][TN]
);

  logic [COMMIT_WIDTH-1:0] is_jal;
  logic [COMMIT_WIDTH-1:0] is_jalr;
  logic [COMMIT_WIDTH-1:0] is_br;
  logic [COMMIT_WIDTH-1:0] is_call;
  logic [COMMIT_WIDTH-1:0] is_icall;
  logic [COMMIT_WIDTH-1:0] is_ret;
  logic [COMMIT_WIDTH-1:0] class_dir;
  logic [2:0]  class_br_type [COMMIT_WIDTH];
  logic [31:0] class_target  [COMMIT_WIDTH];

  // instruction class of each commit slot (Ref: back2front_comb)
  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      is_jal[i]  = (commit_type[i] == INST_JAL);
      is_jalr[i] = (commit_type[i] == INST_JALR);
      is_br[i]   = (commit_type[i] == INST_BR);
      // jalr rd=ra (never a return: that has rd=x0)
      is_icall[i] = is_jalr[i] && commit_dest_en[i] && (commit_dest_areg[i] == 6'd1);
      is_call[i] = (is_jal[i] && commit_dest_en[i] && (commit_dest_areg[i] == 6'd1)) || is_icall[i];
      is_ret[i]  = is_jalr[i] && (commit_src1_areg[i] == 6'd1) && (commit_dest_areg[i] == 6'd0)
                   && (commit_imm[i] == 32'd0);
      class_dir[i]    = is_jal[i] || is_jalr[i] || commit_br_taken[i];
      class_target[i] = (is_br[i] || is_jal[i] || is_jalr[i]) ? commit_diag_val[i] : ftq_pc[i] + 32'd4;
      if (is_icall[i])     class_br_type[i] = BR_ICALL;
      else if (is_call[i]) class_br_type[i] = BR_CALL;
      else if (is_ret[i])  class_br_type[i] = BR_RET;
      else if (is_jalr[i]) class_br_type[i] = BR_IDIRECT;
      else if (is_jal[i])  class_br_type[i] = BR_JAL;
      else if (is_br[i])   class_br_type[i] = BR_DIRECT;
      else                 class_br_type[i] = BR_NONCTL;
    end
  end

  // next-state of the update bundle: payload only for valid slots
  logic [COMMIT_WIDTH-1:0] upd_valid_d;
  logic [31:0] upd_base_pc_d [COMMIT_WIDTH];
  logic [COMMIT_WIDTH-1:0] upd_actual_dir_d;
  logic [2:0]  upd_br_type_d [COMMIT_WIDTH];
  logic [31:0] upd_target_d [COMMIT_WIDTH];
  logic [COMMIT_WIDTH-1:0] upd_pred_dir_d;
  logic [COMMIT_WIDTH-1:0] upd_alt_pred_d;
  logic [2:0]  upd_pcpn_d [COMMIT_WIDTH];
  logic [7:0]  upd_tags_d [COMMIT_WIDTH][TN];
  logic [9:0]  upd_idxs_d [COMMIT_WIDTH][TN];

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      upd_valid_d[i]      = commit_valid[i];
      upd_base_pc_d[i]    = commit_valid[i] ? ftq_pc[i]          : 32'd0;
      upd_actual_dir_d[i] = commit_valid[i] && class_dir[i];
      upd_br_type_d[i]    = commit_valid[i] ? class_br_type[i]   : 3'd0;
      upd_target_d[i]     = commit_valid[i] ? class_target[i]    : 32'd0;
      upd_pred_dir_d[i]   = commit_valid[i] && ftq_pred_taken[i];
      upd_alt_pred_d[i]   = commit_valid[i] && ftq_alt_pred[i];
      upd_pcpn_d[i]       = commit_valid[i] ? ftq_pcpn[i]        : 3'd0;
      for (int j = 0; j < TN; j++) begin
        upd_tags_d[i][j] = commit_valid[i] ? ftq_tage_tag[i][j] : 8'd0;
        upd_idxs_d[i][j] = commit_valid[i] ? ftq_tage_idx[i][j] : 10'd0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      refetch_q         <= 1'b0;
      refetch_address_q <= 32'd0;
      rf_valid_q        <= 1'b0;
      rf_ck_q           <= '0;
      rf_epoch_q        <= '0;
      rf_type_q         <= '0;
      rf_pc_q           <= '0;
      itlb_flush_q      <= 1'b0;
      fence_i_q         <= 1'b0;
      stall_q           <= 1'b0;
    end else begin
      refetch_q         <= out_mispred;
      refetch_address_q <= out_redirect_pc;   // only read in refetch cycles
      rf_valid_q        <= out_rf_valid;
      rf_ck_q           <= out_rf_ck;         // the repair record is only read in refetch cycles
      rf_epoch_q        <= out_rf_epoch;
      rf_type_q         <= out_rf_type;
      rf_pc_q           <= out_rf_pc;
      itlb_flush_q      <= rob_bcast_fence;
      fence_i_q         <= rob_bcast_fence_i;
      stall_q           <= out_stall;
    end
  end

  for (genvar i = 0; i < COMMIT_WIDTH; i++) begin : g_lane
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        upd_valid_q[i]      <= 1'b0;
        upd_base_pc_q[i]    <= 32'd0;
        upd_actual_dir_q[i] <= 1'b0;
        upd_br_type_q[i]    <= 3'd0;
        upd_target_q[i]     <= 32'd0;
        upd_pred_dir_q[i]   <= 1'b0;
        upd_alt_pred_q[i]   <= 1'b0;
        upd_pcpn_q[i]       <= 3'd0;
        upd_tags_q[i]       <= '{default: '0};
        upd_idxs_q[i]       <= '{default: '0};
      end else begin
        upd_valid_q[i]      <= upd_valid_d[i];
        upd_base_pc_q[i]    <= upd_base_pc_d[i];
        upd_actual_dir_q[i] <= upd_actual_dir_d[i];
        upd_br_type_q[i]    <= upd_br_type_d[i];
        upd_target_q[i]     <= upd_target_d[i];
        upd_pred_dir_q[i]   <= upd_pred_dir_d[i];
        upd_alt_pred_q[i]   <= upd_alt_pred_d[i];
        upd_pcpn_q[i]       <= upd_pcpn_d[i];
        upd_tags_q[i]       <= upd_tags_d[i];
        upd_idxs_q[i]       <= upd_idxs_d[i];
      end
    end
  end


endmodule

`default_nettype wire
