// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_exe2lsu: handle_load_req)
`default_nettype none

// G: load address requests of the EXU.  Matches on the ROB tag only; the entry state is not looked at
// (C++ overwrites whatever it is).
module lsu_exe_in_ld
  import lsu_pkg::*;
(
  input  logic [NLD-1:0]   req_valid,
  input  logic [31:0]      req_result    [NLD],      // virtual address
  input  logic [PRFW-1:0]  req_dest_preg [NLD],
  input  logic [2:0]       req_func3     [NLD],
  input  logic [NLD-1:0]   req_is_atomic,
  input  logic [4:0]       req_amo_op    [NLD],
  input  logic [ROBW-1:0]  req_rob_idx   [NLD],
  input  logic             req_rob_flag  [NLD],
  input  logic [SQW-1:0]   req_stq_idx   [NLD],      // STQ tail snapshot at dispatch
  input  logic             req_stq_flag  [NLD],
  input  logic [LQW-1:0]   req_ldq_idx   [NLD],
  input  ldq_fld_t         fld_q         [LQ],
  output ldq_agu_t         ev            [LQ],
  output lsu_rop_t         wmld_op                    // wait_mmu_ldq append
);

  logic [NLD-1:0] hit;
  for (genvar p = 0; p < NLD; p++) begin : g_hit
    assign hit[p] = req_valid[p] && fld_q[req_ldq_idx[p]].rob_idx == req_rob_idx[p] &&
                    fld_q[req_ldq_idx[p]].rob_flag == req_rob_flag[p];
  end

  for (genvar e = 0; e < LQ; e++) begin : g_entry
    logic [NLD-1:0] sel;
    for (genvar p = 0; p < NLD; p++) begin : g_p
      assign sel[p] = hit[p] && req_ldq_idx[p] == LQW'(e);
    end
    always_comb begin
      ev[e]    = '0;
      ev[e].go = |sel;
      for (int p = NLD - 1; p >= 0; p--) begin
        if (sel[p]) begin
          ev[e].vaddr     = req_result[p];
          ev[e].dest      = req_dest_preg[p];
          ev[e].func3     = req_func3[p];
          ev[e].snap_idx  = req_stq_idx[p];
          ev[e].snap_flag = req_stq_flag[p];
          ev[e].lrsc      = req_is_atomic[p] && req_amo_op[p] == AMO_LR;
        end
      end
    end
  end

  logic [WIN-1:0]          a_en;
  logic [WIN-1:0][RIW-1:0] a_idx;
  always_comb begin
    a_en  = '0;
    a_idx = '0;
    for (int p = 0; p < NLD; p++) begin
      a_en[p]  = hit[p];
      a_idx[p] = req_ldq_idx[p];
    end
  end
  assign wmld_op = rop_app(a_en, a_idx);

endmodule

`default_nettype wire
