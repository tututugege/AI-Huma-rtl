// Ref: back-end/Exu/Exu.cpp  Exu::seq / Exu::ready (ISS -> RR pipeline register, Wall #2)
`default_nettype none

module iss_rr_reg
  import ttg_cfg_pkg::*;
  import isu_pkg::isu_uop_t;
  import ttg_util_pkg::ttg_rob_younger;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        flush,
  input  logic                        mispred,
  input  logic [ROB_IDX_WIDTH-1:0]    dec_rob_idx,
  input  logic                        dec_rob_flag,
  input  logic [LSU_LDU_COUNT-1:0]    cancel_valid,
  input  logic [ISSUE_WIDTH-1:0]      iss_valid,
  input  isu_uop_t                    iss_uop       [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0]          iss_src1_byp  [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0]          iss_src2_byp  [ISSUE_WIDTH],
  input  logic [LSU_LDU_COUNT-1:0]    iss_spec_mask [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0]      rr_valid,
  output isu_uop_t                    rr_uop        [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0]          rr_src1_byp   [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0]          rr_src2_byp   [ISSUE_WIDTH]
);

  logic [ISSUE_WIDTH-1:0]             valid_q, valid_d, rr_live;
  isu_uop_t                           uop_q       [ISSUE_WIDTH];
  logic [ALU_NUM-1:0]                 src1_byp_q  [ISSUE_WIDTH];
  logic [ALU_NUM-1:0]                 src2_byp_q  [ISSUE_WIDTH];
  logic [LSU_LDU_COUNT-1:0]           spec_mask_q [ISSUE_WIDTH];

  always_comb begin
    for (int p = 0; p < ISSUE_WIDTH; p++) begin
      valid_d[p] = !flush && iss_valid[p] &&
                   !(mispred && ttg_rob_younger(iss_uop[p].rob_idx, iss_uop[p].rob_flag,
                                                dec_rob_idx, dec_rob_flag));
      rr_live[p] = !flush && valid_q[p] &&
                   !(mispred && ttg_rob_younger(uop_q[p].rob_idx, uop_q[p].rob_flag,
                                                dec_rob_idx, dec_rob_flag));
      rr_valid[p]    = rr_live[p] && !(|(spec_mask_q[p] & cancel_valid));
      rr_uop[p]      = uop_q[p];
      rr_src1_byp[p] = src1_byp_q[p];
      rr_src2_byp[p] = src2_byp_q[p];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
      for (int p = 0; p < ISSUE_WIDTH; p++) begin
        uop_q[p]       <= '0;
        src1_byp_q[p]  <= '0;
        src2_byp_q[p]  <= '0;
        spec_mask_q[p] <= '0;
      end
    end else begin
      valid_q <= valid_d;
      for (int p = 0; p < ISSUE_WIDTH; p++) begin
        if (valid_d[p]) begin
          uop_q[p]       <= iss_uop[p];
          src1_byp_q[p]  <= iss_src1_byp[p];
          src2_byp_q[p]  <= iss_src2_byp[p];
          spec_mask_q[p] <= iss_spec_mask[p];
        end else if (flush) begin
          spec_mask_q[p] <= '0;
        end
      end
    end
  end

endmodule

`default_nettype wire
