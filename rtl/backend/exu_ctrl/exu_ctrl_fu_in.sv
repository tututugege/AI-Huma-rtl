// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu_exec (in.fu2exu->entry[i] <- units[i]->out)
`default_nettype none

// FU results per FU instance: the flat group arrays of the spec ports gathered into one record per FU
// (single-cycle FUs hand back only computed fields, multi-cycle FUs the whole handshake).
module exu_ctrl_fu_in
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
  import fp_pkg::*;
(
  input  logic [XLEN_BITS-1:0]               fu_alu_result [ALU_NUM],
  input  logic [XLEN_BITS-1:0]               fu_agu_result [LSU_AGU_COUNT],
  input  logic [XLEN_BITS-1:0]               fu_sdu_result [LSU_SDU_COUNT],
  input  logic [XLEN_BITS-1:0]               fu_bru_diag_val [BRU_NUM],
  input  logic                      fu_bru_mispred [BRU_NUM],
  input  logic                      fu_bru_br_taken [BRU_NUM],
  input  logic [N_MC-1:0] fu_mc_complete,
  input  logic [XLEN_BITS-1:0]               fu_mc_result [N_MC],
  input  logic [PRF_IDX_WIDTH-1:0]  fu_mc_dest_preg [N_MC],
  input  logic [N_MC-1:0] fu_mc_dest_en,
  input  logic [ROB_IDX_WIDTH-1:0]  fu_mc_rob_idx [N_MC],
  input  logic [N_MC-1:0] fu_mc_rob_flag,
  input  logic [N_FPU-1:0]          fu_fp_complete,
  input  logic [XLEN_BITS-1:0]      fu_fp_result [N_FPU],
  input  logic [FW-1:0]             fu_fp_fresult [N_FPU],
  input  logic [FFLAGS_W-1:0]       fu_fp_fflags [N_FPU],
  input  logic [N_FPU-1:0]          fu_fp_illegal,
  input  logic [PRF_IDX_WIDTH-1:0]  fu_fp_dest_preg [N_FPU],
  input  logic [N_FPU-1:0]          fu_fp_dest_en,
  input  logic [ROB_IDX_WIDTH-1:0]  fu_fp_rob_idx [N_FPU],
  input  logic [N_FPU-1:0]          fu_fp_rob_flag,
  output xc_fu_res_t                fu_res [N_FU]
);

  // Each FU's kind is a constant, so the per-kind selection is a generate branch: only the arm of this FU's kind is
  // elaborated (a run-time case over KIND would also elaborate the other arms, whose rank indexes another kind's array
  // and can be out of range there).
  for (genvar f = 0; f < N_FU; f++) begin : g_res
    localparam int KIND = xc_fu_kind(f);
    localparam int RK   = xc_kind_rank(f);
    xc_fu_res_t res;
    if (KIND == XC_K_ALU) begin : g_alu
      always_comb begin res = '0; res.result = fu_alu_result[RK]; end
    end else if (KIND == XC_K_AGU) begin : g_agu
      always_comb begin res = '0; res.result = fu_agu_result[RK]; end
    end else if (KIND == XC_K_STD) begin : g_std
      always_comb begin res = '0; res.result = fu_sdu_result[RK]; end
    end else if (KIND == XC_K_BR) begin : g_br
      always_comb begin
        res          = '0;
        res.diag_val = fu_bru_diag_val[RK];
        res.mispred  = fu_bru_mispred[RK];
        res.br_taken = fu_bru_br_taken[RK];
      end
    end else if (xc_is_mc_kind(KIND)) begin : g_mc
      localparam int MR = xc_mc_rank(f);
      always_comb begin
        res             = '0;
        res.mc_complete = fu_mc_complete[MR];
        res.result      = fu_mc_result[MR];
        res.dest_preg   = fu_mc_dest_preg[MR];
        res.dest_en     = fu_mc_dest_en[MR];
        res.rob_idx     = fu_mc_rob_idx[MR];
        res.rob_flag    = fu_mc_rob_flag[MR];
      end
    end else if (xc_is_fp_kind(KIND) != 0) begin : g_fp
      localparam int FR = xc_fp_rank(f);
      always_comb begin
        res             = '0;
        res.mc_complete = fu_fp_complete[FR];
        res.result      = fu_fp_result[FR];
        res.fresult     = fu_fp_fresult[FR];
        res.fflags      = fu_fp_fflags[FR];
        res.illegal     = fu_fp_illegal[FR];
        res.dest_preg   = fu_fp_dest_preg[FR];
        res.dest_en     = fu_fp_dest_en[FR];
        res.rob_idx     = fu_fp_rob_idx[FR];
        res.rob_flag    = fu_fp_rob_flag[FR];
      end
    end else begin : g_none
      assign res = '0;
    end
    assign fu_res[f] = res;
  end

endmodule

`default_nettype wire
