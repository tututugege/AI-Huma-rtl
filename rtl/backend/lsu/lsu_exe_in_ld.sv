// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_exe2lsu: handle_load_req)
`default_nettype none

module lsu_exe_in_ld
  import lsu_pkg::*;
(
  input  logic [NLD-1:0]   req_valid,
  input  logic [31:0]      req_result    [NLD],      // virtual address
  input  logic [6:0]       req_dest_preg [NLD],
  input  logic [2:0]       req_func3     [NLD],
  input  logic [NLD-1:0]   req_is_atomic,
  input  logic [4:0]       req_amo_op    [NLD],
  input  logic [6:0]       req_rob_idx   [NLD],
  input  logic             req_rob_flag  [NLD],
  input  logic [SQW-1:0]   req_stq_idx   [NLD],      // STQ tail snapshot at dispatch
  input  logic             req_stq_flag  [NLD],
  input  logic [LQW-1:0]   req_ldq_idx   [NLD],
  input  logic [6:0]       ld_rob_idx    [LQ],
  input  logic [LQ-1:0]    ld_rob_flag,
  input  lsu_ring_t        wmld_i,
  input  ld_state_t        ld_st_i       [LQ],
  input  logic [31:0]      ld_vaddr_i    [LQ],
  input  logic [6:0]       ld_dest_i     [LQ],
  input  logic [2:0]       ld_func3_i    [LQ],
  input  logic [SQW-1:0]   ld_snap_idx_i [LQ],
  input  logic [LQ-1:0]    ld_snap_flag_i,
  input  logic [LQ-1:0]    ld_lrsc_i,
  output lsu_ring_t        wmld_o,
  output ld_state_t        ld_st_o       [LQ],
  output logic [31:0]      ld_vaddr_o    [LQ],
  output logic [6:0]       ld_dest_o     [LQ],
  output logic [2:0]       ld_func3_o    [LQ],
  output logic [SQW-1:0]   ld_snap_idx_o [LQ],
  output logic [LQ-1:0]    ld_snap_flag_o,
  output logic [LQ-1:0]    ld_lrsc_o
);

  // matches on the ROB tag only; the entry state is not looked at (C++ overwrites whatever it is)
  logic [NLD-1:0] hit;
  for (genvar p = 0; p < NLD; p++) begin : g_hit
    assign hit[p] = req_valid[p] && ld_rob_idx[req_ldq_idx[p]] == req_rob_idx[p] &&
                    ld_rob_flag[req_ldq_idx[p]] == req_rob_flag[p];
  end

  for (genvar e = 0; e < LQ; e++) begin : g_entry
    logic [NLD-1:0] sel;
    for (genvar p = 0; p < NLD; p++) begin : g_p
      assign sel[p] = hit[p] && req_ldq_idx[p] == LQW'(e);
    end
    always_comb begin
      ld_st_o[e]        = (|sel) ? LD_WAIT_TLB : ld_st_i[e];
      ld_vaddr_o[e]     = ld_vaddr_i[e];
      ld_dest_o[e]      = ld_dest_i[e];
      ld_func3_o[e]     = ld_func3_i[e];
      ld_snap_idx_o[e]  = ld_snap_idx_i[e];
      ld_snap_flag_o[e] = ld_snap_flag_i[e];
      ld_lrsc_o[e]      = ld_lrsc_i[e];
      for (int p = NLD - 1; p >= 0; p--) begin
        if (sel[p]) begin
          ld_vaddr_o[e]     = req_result[p];
          ld_dest_o[e]      = req_dest_preg[p];
          ld_func3_o[e]     = req_func3[p];
          ld_snap_idx_o[e]  = req_stq_idx[p];
          ld_snap_flag_o[e] = req_stq_flag[p];
          ld_lrsc_o[e]      = req_is_atomic[p] && req_amo_op[p] == AMO_LR;
        end
      end
    end
  end

  lsu_ring_app #(.NA(NLD)) u_wmld (.ring_i(wmld_i), .app_en(hit), .app_idx(req_ldq_idx), .ring_o(wmld_o));

endmodule

`default_nettype wire
