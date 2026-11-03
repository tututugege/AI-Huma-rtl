// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_exe2lsu: handle_store_data, handle_store_addr)
`default_nettype none

// G: STD and STA requests of the EXU.  A request only takes effect when it matches the entry's ROB tag
// (stale/mismatching requests are dropped); the entry's own state is not looked at.
module lsu_exe_in_st
  import lsu_pkg::*;
(
  input  logic [NSDU-1:0]  sdu_valid,
  input  logic [31:0]      sdu_result    [NSDU],
  input  logic [ROBW-1:0]  sdu_rob_idx   [NSDU],
  input  logic             sdu_rob_flag  [NSDU],
  input  logic [SQW-1:0]   sdu_stq_idx   [NSDU],
  input  logic [NST-1:0]   sta_valid,
  input  logic [31:0]      sta_result    [NST],
  input  logic [PRFW-1:0]  sta_dest_preg [NST],
  input  logic [2:0]       sta_func3     [NST],
  input  logic [NST-1:0]   sta_is_atomic,
  input  logic [4:0]       sta_amo_op    [NST],
  input  logic [ROBW-1:0]  sta_rob_idx   [NST],
  input  logic             sta_rob_flag  [NST],
  input  logic [SQW-1:0]   sta_stq_idx   [NST],
  input  st_state_t        st_dc         [SQ],
  input  stq_fld_t         fld_q         [SQ],
  output stq_ex_t          ev            [SQ],
  output lsu_rop_t         mdone_op,            // STD completions -> mmu_done
  output lsu_rop_t         wmst_op              // STA -> wait_mmu_stq
);

  logic [NSDU-1:0] sdu_hit, sdu_ready;
  logic [NST-1:0]  sta_hit;
  for (genvar p = 0; p < NSDU; p++) begin : g_sdu
    assign sdu_hit[p]   = sdu_valid[p] && fld_q[sdu_stq_idx[p]].rob_idx == sdu_rob_idx[p] &&
                          fld_q[sdu_stq_idx[p]].rob_flag == sdu_rob_flag[p];
    assign sdu_ready[p] = sdu_hit[p] && fld_q[sdu_stq_idx[p]].paddr_valid && st_dc[sdu_stq_idx[p]] == ST_WAIT_DATA;
  end
  for (genvar p = 0; p < NST; p++) begin : g_sta
    assign sta_hit[p] = sta_valid[p] && fld_q[sta_stq_idx[p]].rob_idx == sta_rob_idx[p] &&
                        fld_q[sta_stq_idx[p]].rob_flag == sta_rob_flag[p];
  end

  for (genvar e = 0; e < SQ; e++) begin : g_entry
    logic [NSDU-1:0] d_sel, r_sel;
    logic [NST-1:0]  a_sel;
    for (genvar p = 0; p < NSDU; p++) begin : g_d
      assign d_sel[p] = sdu_hit[p] && sdu_stq_idx[p] == SQW'(e);
      assign r_sel[p] = sdu_ready[p] && sdu_stq_idx[p] == SQW'(e);
    end
    for (genvar p = 0; p < NST; p++) begin : g_a
      assign a_sel[p] = sta_hit[p] && sta_stq_idx[p] == SQW'(e);
    end
    always_comb begin
      ev[e]         = '0;
      ev[e].std_go  = |d_sel;
      ev[e].std_rdy = |r_sel;
      ev[e].sta_go  = |a_sel;
      for (int p = NSDU - 1; p >= 0; p--) if (d_sel[p]) ev[e].data = sdu_result[p];
      for (int p = NST - 1; p >= 0; p--) begin
        if (a_sel[p]) begin
          ev[e].vaddr = sta_result[p];
          ev[e].func3 = sta_func3[p];
          ev[e].dest  = sta_dest_preg[p];
          ev[e].lrsc  = sta_is_atomic[p] && sta_amo_op[p] == AMO_SC;
        end
      end
    end
  end

  // queue appends in port order
  logic [WIN-1:0]          d_en, a_en;
  logic [WIN-1:0][RIW-1:0] d_idx, a_idx;
  always_comb begin
    d_en = '0;
    a_en = '0;
    d_idx = '0;
    a_idx = '0;
    for (int p = 0; p < NSDU; p++) begin
      d_en[p]  = sdu_ready[p];
      d_idx[p] = sdu_stq_idx[p];
    end
    for (int p = 0; p < NST; p++) begin
      a_en[p]  = sta_hit[p];
      a_idx[p] = sta_stq_idx[p];
    end
  end
  assign mdone_op = rop_app(d_en, d_idx);
  assign wmst_op  = rop_app(a_en, a_idx);

endmodule

`default_nettype wire
