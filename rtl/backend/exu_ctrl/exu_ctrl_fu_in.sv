// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu_exec (in.fu2exu->entry[i] <- units[i]->out)
`default_nettype none

// FU results per FU instance: the flat group arrays of the spec ports gathered into one record per FU
// (single-cycle FUs hand back only computed fields, multi-cycle FUs the whole handshake).
module exu_ctrl_fu_in
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic [31:0]               fu_alu_result [ALU_NUM],
  input  logic [31:0]               fu_agu_result [LSU_AGU_COUNT],
  input  logic [31:0]               fu_sdu_result [LSU_SDU_COUNT],
  input  logic [31:0]               fu_bru_diag_val [BRU_NUM],
  input  logic                      fu_bru_mispred [BRU_NUM],
  input  logic                      fu_bru_br_taken [BRU_NUM],
  input  logic                      fu_mc_ready [N_MC],
  input  logic                      fu_mc_complete [N_MC],
  input  logic [31:0]               fu_mc_result [N_MC],
  input  logic [PRF_IDX_WIDTH-1:0]  fu_mc_dest_preg [N_MC],
  input  logic                      fu_mc_dest_en [N_MC],
  input  logic [BR_MASK_WIDTH-1:0]  fu_mc_br_mask [N_MC],
  input  logic [ROB_IDX_WIDTH-1:0]  fu_mc_rob_idx [N_MC],
  output xc_fu_res_t                fu_res [N_FU]
);

  for (genvar f = 0; f < N_FU; f++) begin : g_res
    localparam int KIND = xc_fu_kind(f);
    xc_fu_res_t res;
    always_comb begin
      res = '0;
      case (KIND)
        XC_K_ALU: res.result = fu_alu_result[xc_kind_rank(f)];
        XC_K_LD:  res.result = fu_agu_result[xc_kind_rank(f)];
        XC_K_STA: res.result = fu_agu_result[LSU_LDU_COUNT + xc_kind_rank(f)];
        XC_K_STD: res.result = fu_sdu_result[xc_kind_rank(f)];
        XC_K_BR: begin
          res.diag_val = fu_bru_diag_val[xc_kind_rank(f)];
          res.mispred  = fu_bru_mispred[xc_kind_rank(f)];
          res.br_taken = fu_bru_br_taken[xc_kind_rank(f)];
        end
        default: ;
      endcase
      if (xc_is_mc_kind(KIND)) begin
        res.mc_ready    = fu_mc_ready[xc_mc_rank(f)];
        res.mc_complete = fu_mc_complete[xc_mc_rank(f)];
        res.result      = fu_mc_result[xc_mc_rank(f)];
        res.dest_preg   = fu_mc_dest_preg[xc_mc_rank(f)];
        res.dest_en     = fu_mc_dest_en[xc_mc_rank(f)];
        res.br_mask     = fu_mc_br_mask[xc_mc_rank(f)];
        res.rob_idx     = fu_mc_rob_idx[xc_mc_rank(f)];
      end
    end
    assign fu_res[f] = res;
  end

endmodule

`default_nettype wire
