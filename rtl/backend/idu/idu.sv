// Ref: back-end/Idu.cpp  class Idu  (comb_branch / comb_decode / comb_fire / seq)
`default_nettype none

// Idu top: pure combinational 8-wide decoder (idu_br_latch moved to back_top after EXP-068).
module idu
  import ttg_cfg_pkg::*;
  import ftq_ibuf_pkg::ib_entry_t;
  import ren_pkg::ren_inst_t;
(
  // ftq_ibuf issue group
  input  logic [DECODE_WIDTH-1:0] ibuf2idu_valid,
  input  ib_entry_t               ibuf2idu_entry [DECODE_WIDTH],
  // rename ready, ROB flush, mispredict broadcast (from back_top u_br_latch)
  input  logic                    ren2dec_ready,
  input  logic                    rob_bcast_flush,
  input  logic                    dec_bcast_mispred,
  // dec2ren
  output logic [DECODE_WIDTH-1:0] dec2ren_valid,
  output ren_inst_t               dec2ren_uop [DECODE_WIDTH],
  // idu_consume
  output logic [DECODE_WIDTH-1:0] idu_consume_fire
);

  /* verilator lint_off UNUSEDSIGNAL */
  logic [DECODE_WIDTH-1:0] lane_is_branch;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- decode lanes ----
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_lane
    assign dec2ren_valid[i]    = ibuf2idu_valid[i];
    assign idu_consume_fire[i] = ibuf2idu_valid[i] && ren2dec_ready && !rob_bcast_flush && !dec_bcast_mispred;

    idu_decoder u_dec (
      .entry_valid(ibuf2idu_valid[i]),
      .entry_inst(ibuf2idu_entry[i].inst),
      .entry_page_fault_inst(ibuf2idu_entry[i].page_fault_inst),
      .entry_pf_inst_hi(ibuf2idu_entry[i].pf_inst_hi),
      .entry_ftq_idx(ibuf2idu_entry[i].ftq_idx),
      .entry_ftq_offset(ibuf2idu_entry[i].ftq_offset),
      .entry_ftq_is_last(ibuf2idu_entry[i].ftq_is_last),
      .uop_diag_val(dec2ren_uop[i].diag_val),
      .uop_dest_areg(dec2ren_uop[i].dest_areg),
      .uop_src1_areg(dec2ren_uop[i].src1_areg),
      .uop_src2_areg(dec2ren_uop[i].src2_areg),
      .uop_ftq_idx(dec2ren_uop[i].ftq_idx),
      .uop_ftq_offset(dec2ren_uop[i].ftq_offset),
      .uop_ftq_is_last(dec2ren_uop[i].ftq_is_last),
      .uop_type(dec2ren_uop[i].inst_type),
      .uop_dest_en(dec2ren_uop[i].dest_en),
      .uop_src1_en(dec2ren_uop[i].src1_en),
      .uop_src2_en(dec2ren_uop[i].src2_en),
      .uop_is_atomic(dec2ren_uop[i].is_atomic),
      .uop_src1_is_pc(dec2ren_uop[i].src1_is_pc),
      .uop_src2_is_imm(dec2ren_uop[i].src2_is_imm),
      .uop_is_word(dec2ren_uop[i].is_word),
      .uop_func3(dec2ren_uop[i].func3),
      .uop_func7(dec2ren_uop[i].func7),
      .uop_imm(dec2ren_uop[i].imm),
      .uop_csr_idx(dec2ren_uop[i].csr_idx),
      .uop_page_fault_inst(dec2ren_uop[i].page_fault_inst),
      .uop_pf_inst_hi(dec2ren_uop[i].pf_inst_hi),
      .uop_illegal_inst(dec2ren_uop[i].illegal_inst),
      .uop_dest_fp(dec2ren_uop[i].dest_fp),
      .uop_src1_fp(dec2ren_uop[i].src1_fp),
      .uop_src2_fp(dec2ren_uop[i].src2_fp),
      .uop_src3_en(dec2ren_uop[i].src3_en),
      .uop_src3_areg(dec2ren_uop[i].src3_areg),
      .uop_fp_cls(dec2ren_uop[i].fp_cls),
      .is_branch(lane_is_branch[i])
    );
  end

endmodule

`default_nettype wire
