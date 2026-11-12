// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (in.fu2exu->entry[i].inst);  AbstractFU.h  class SingleCycleFU
`default_nettype none

// One uniform "finished result" record per FU. A single-cycle FU finishes in the cycle it is dispatched
// (complete == en)
// and its instruction is the slot instruction plus the computed fields; a multi-cycle FU (MUL/DIV/FP) reports the
// instruction it holds itself.
module exu_ctrl_fu_view
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic [N_FU-1:0] fu_en,
  input  xc_inst_t        fu_inst [N_FU],
  input  xc_fu_res_t      fu_res  [N_FU],
  output xc_done_t        fu_done [N_FU]
);

  for (genvar f = 0; f < N_FU; f++) begin : g_fu
    localparam bit IS_FP = xc_is_fp_kind(xc_fu_kind(f));
    localparam bit MULTI_CYCLE = xc_is_mc_kind(xc_fu_kind(f)) || IS_FP;
    localparam xc_op_t MC_OP = IS_FP ? xc_op_t'(xc_fp_op(xc_fu_kind(f))) : xc_op_t'(xc_mc_op(xc_fu_kind(f)));
    xc_done_t done;

    // Ref: Exu::comb_fu_exec (collect of units[i]->out)
    always_comb begin
      done = '0;
      if (MULTI_CYCLE) begin
        done.complete  = fu_res[f].mc_complete;
        done.result    = fu_res[f].result;
        done.fresult   = fu_res[f].fresult;
        done.fflags    = fu_res[f].fflags;
        done.dest_preg = fu_res[f].dest_preg;
        done.dest_en   = fu_res[f].dest_en;
        done.br_mask   = fu_res[f].br_mask;
        done.rob_idx   = fu_res[f].rob_idx;
        done.op        = MC_OP;
      end else begin
        done.complete  = fu_en[f];
        done.result    = fu_res[f].result;
        done.dest_preg = fu_inst[f].dest_preg;
        done.dest_en   = fu_inst[f].dest_en;
        done.br_mask   = fu_inst[f].br_mask;
        done.op        = fu_inst[f].op;
        done.rob_idx   = fu_inst[f].rob_idx;
        done.rob_flag  = fu_inst[f].rob_flag;
        done.diag_val  = fu_res[f].diag_val;
        done.mispred   = fu_res[f].mispred;
        done.br_taken  = fu_res[f].br_taken;
        done.br_id     = fu_inst[f].br_id;
        done.ftq_idx   = fu_inst[f].ftq_idx;
        done.pc        = fu_inst[f].pc;
        done.func3     = fu_inst[f].func3;
        done.amo_op    = fu_inst[f].func7[6:2];
        done.is_atomic = fu_inst[f].is_atomic;
        done.stq_idx   = fu_inst[f].stq_idx;
        done.stq_flag  = fu_inst[f].stq_flag;
        done.ldq_idx   = fu_inst[f].ldq_idx;
      end
    end
    assign fu_done[f] = done;
  end

endmodule

`default_nettype wire
