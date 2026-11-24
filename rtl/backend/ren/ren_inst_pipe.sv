// Ref: back-end/Ren.cpp  class Ren  (inst_r, inst_valid; Ren::comb_pipeline)
`default_nettype none

// Two-stage rename pipeline (S1 -> S2):
//   S1 holds the decoded group from IDU and pre-decodes RAT one-hot addresses, move_shape, is_branch, and
//   intra-group areg dependency matrices before S2, cutting decoders & comparators off the S2 RAT critical path.
//   S2 holds the group + pre-decoded metadata until every valid slot has fired.
module ren_inst_pipe
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [N-1:0]        dec_valid,
  input  ren_inst_t           dec_uop [N],
  input  logic                s1_take_new,  // ren2dec.ready: accept next group from decode into S1
  input  logic                s2_take_new,  // advance S1 -> S2
  input  logic                kill,         // flush or mispredict: drop both S1 and S2
  input  logic [N-1:0]        fire,
  input  br_mask_t            clear_mask,   // resolved-branch bits to clear from every br_mask
  output logic                s1_empty,
  output logic [N-1:0]        valid,
  output ren_inst_t           inst [N],
  // Pre-decoded S2 metadata (latched on s2_take_new from S1)
  output logic [RAT_NUM-1:0]  rd_oh_q [3*N],
  output logic [RAT_NUM-1:0]  wr_oh_q [N],
  output logic [N-1:0]        move_shape_q,
  output logic [N-1:0]        is_branch_q,
  output logic [N-1:0]        raw_hit_dest_q [N],
  output logic [N-1:0]        raw_hit_src1_q [N],
  output logic [N-1:0]        raw_hit_src2_q [N]
);

  // ---- Stage 1 registers ----
  logic [N-1:0] s1_valid_q, s1_valid_d;
  ren_inst_t    s1_inst_q [N], s1_inst_d [N];

  assign s1_empty = (s1_valid_q == '0);

  always_comb begin
    for (int i = 0; i < N; i++) begin
      s1_inst_d[i]         = s1_take_new ? dec_uop[i] : s1_inst_q[i];
      s1_inst_d[i].br_mask = s1_inst_d[i].br_mask & ~clear_mask;
    end
    if (kill)             s1_valid_d = '0;
    else if (s1_take_new) s1_valid_d = dec_valid;
    else if (s2_take_new) s1_valid_d = '0;
    else                  s1_valid_d = s1_valid_q;
  end

  // ---- Stage 1 combinational pre-decode (feeds S2 metadata registers) ----
  logic [RAT_NUM-1:0] s1_rd_oh [3*N];
  logic [RAT_NUM-1:0] s1_wr_oh [N];
  logic [N-1:0]       s1_move_shape, s1_is_branch;
  logic [N-1:0]       s1_hit_dest [N], s1_hit_src1 [N], s1_hit_src2 [N];

  always_comb begin
    for (int i = 0; i < N; i++) begin
      for (int e = 0; e < RAT_NUM; e++) begin
        s1_rd_oh[i][e]       = (s1_inst_q[i].dest_areg == areg_t'(e));
        s1_rd_oh[N + i][e]   = (s1_inst_q[i].src1_areg == areg_t'(e));
        s1_rd_oh[2*N + i][e] = (s1_inst_q[i].src2_areg == areg_t'(e));
        s1_wr_oh[i][e]       = (s1_inst_q[i].dest_areg == areg_t'(e));
      end
      s1_move_shape[i] = ren_is_move_shape(s1_inst_q[i].inst_type, s1_inst_q[i].src2_is_imm,
                                           s1_inst_q[i].is_word, s1_inst_q[i].func3, s1_inst_q[i].imm,
                                           s1_inst_q[i].src1_en, s1_inst_q[i].src1_is_pc, s1_inst_q[i].src1_areg,
                                           s1_inst_q[i].dest_en, s1_inst_q[i].dest_areg);
      s1_is_branch[i]  = (s1_inst_q[i].inst_type == ITYPE_BR) | (s1_inst_q[i].inst_type == ITYPE_JALR);
      s1_hit_dest[i]   = '0;
      s1_hit_src1[i]   = '0;
      s1_hit_src2[i]   = '0;
      for (int j = 0; j < i; j++) begin
        logic int_dest_j;
        int_dest_j = s1_inst_q[j].dest_en & ~s1_inst_q[j].dest_fp;
        s1_hit_dest[i][j] = int_dest_j & (s1_inst_q[i].dest_areg == s1_inst_q[j].dest_areg);
        s1_hit_src1[i][j] = int_dest_j & (s1_inst_q[i].src1_areg == s1_inst_q[j].dest_areg);
        s1_hit_src2[i][j] = int_dest_j & (s1_inst_q[i].src2_areg == s1_inst_q[j].dest_areg);
      end
    end
  end

  // ---- Stage 2 registers ----
  logic [N-1:0] valid_q, valid_d;
  ren_inst_t    inst_q [N], inst_d [N];

  assign valid = valid_q;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      inst[i]           = inst_q[i];
      inst_d[i]         = s2_take_new ? s1_inst_q[i] : inst_q[i];
      inst_d[i].br_mask = inst_d[i].br_mask & ~clear_mask;
    end
    if (kill)             valid_d = '0;
    else if (s2_take_new) valid_d = s1_valid_q;
    else                  valid_d = valid_q & ~fire;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_valid_q   <= '0;
      s1_inst_q    <= '{default: '0};
      valid_q      <= '0;
      inst_q       <= '{default: '0};
      move_shape_q <= '0;
      is_branch_q  <= '0;
      for (int r = 0; r < 3*N; r++) rd_oh_q[r] <= '0;
      for (int i = 0; i < N; i++) begin
        wr_oh_q[i]        <= '0;
        raw_hit_dest_q[i] <= '0;
        raw_hit_src1_q[i] <= '0;
        raw_hit_src2_q[i] <= '0;
      end
    end else begin
      s1_valid_q <= s1_valid_d;
      s1_inst_q  <= s1_inst_d;
      valid_q    <= valid_d;
      inst_q     <= inst_d;
      if (s2_take_new) begin
        move_shape_q <= s1_move_shape;
        is_branch_q  <= s1_is_branch;
        for (int r = 0; r < 3*N; r++) rd_oh_q[r] <= s1_rd_oh[r];
        for (int i = 0; i < N; i++) begin
          wr_oh_q[i]        <= s1_wr_oh[i];
          raw_hit_dest_q[i] <= s1_hit_dest[i];
          raw_hit_src1_q[i] <= s1_hit_src1[i];
          raw_hit_src2_q[i] <= s1_hit_src2[i];
        end
      end
    end
  end

endmodule

`default_nettype wire
