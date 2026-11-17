// Ref: back-end/include/IssueQueue.h  IssueQueue::schedule (CFG_INT_PAR_SELECT: parallel select of the INT queue)
`default_nettype none

// Parallel select of the six-port INT queue (ports: 0 ALU+MUL+CSR, 1 ALU+DIV, 2 ALU+MUL+I2F, 3 ALU+DIV+I2F, 4 and 5 ALU).
// The rare classes each pick their lowest / second-lowest ready slot at once and go to fixed ports:
//   port 0: the CSR uop, else the 1st MUL     port 1: the 1st DIV
//   port 2: the 1st I2F, else the 2nd MUL     port 3: the 2nd DIV, else the 2nd I2F
// The ports left over take the ready ALU-class slots, the k-th lowest slot going to the k-th remaining port in port order.
// (The port-by-port form needs the picks of the earlier ports before a port can choose.)
module isu_int_select
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SIZE = 64
) (
  input  logic [SIZE-1:0] ready,
  input  op_set_t         entry_op [SIZE],
  output logic [SIZE-1:0] sel_onehot [6],
  output logic [5:0]      sel_valid
);

  localparam op_set_t M_CSR = op_set_t'(OP_MASK_CSR);

  logic [SIZE-1:0] r_c, r_m, r_d, r_f, r_a;
  always_comb begin
    for (int i = 0; i < SIZE; i++) begin
      r_c[i] = ready[i] && ((entry_op[i] & M_CSR) != '0);
      r_m[i] = ready[i] && ((entry_op[i] & MASK_MUL) != '0);
      r_d[i] = ready[i] && ((entry_op[i] & MASK_DIV) != '0);
      r_f[i] = ready[i] && FP_EN && ((entry_op[i] & MASK_I2F) != '0);
      r_a[i] = ready[i] && !r_c[i] && !r_m[i] && !r_d[i] && !r_f[i];
    end
  end

  logic [SIZE-1:0] c1 [1], m2 [2], d2 [2], f2 [2], a6 [6];
  isu_rank_onehot #(.N(SIZE), .K(1)) u_c (.set(r_c), .onehot(c1));
  isu_rank_onehot #(.N(SIZE), .K(2)) u_m (.set(r_m), .onehot(m2));
  isu_rank_onehot #(.N(SIZE), .K(2)) u_d (.set(r_d), .onehot(d2));
  isu_rank_onehot #(.N(SIZE), .K(2)) u_f (.set(r_f), .onehot(f2));
  isu_rank_onehot #(.N(SIZE), .K(6)) u_a (.set(r_a), .onehot(a6));

  logic [SIZE-1:0] spec [4];
  logic [3:0]      spec_v;
  always_comb begin
    spec[0] = (|c1[0])  ? c1[0] : m2[0];
    spec[1] = d2[0];
    spec[2] = (|f2[0])  ? f2[0] : m2[1];
    spec[3] = (|d2[1])  ? d2[1] : f2[1];
    for (int p = 0; p < 4; p++) spec_v[p] = |spec[p];
  end

  // ALU ports: the ports without a special pick, in order; port p takes the ALU slot of rank (free ports below p)
  logic [5:0] free_p;
  logic [2:0] free_below [6];
  always_comb begin
    free_p = {2'b11, ~spec_v};
    for (int p = 0; p < 6; p++) begin
      free_below[p] = '0;
      for (int q = 0; q < p; q++) free_below[p] = free_below[p] + 3'(free_p[q]);
    end
  end

  always_comb begin
    for (int p = 0; p < 6; p++) begin
      sel_onehot[p] = '0;
      if (p < 4 && spec_v[p]) sel_onehot[p] = spec[p];
      else for (int k = 0; k < 6; k++) if (free_below[p] == 3'(k)) sel_onehot[p] = a6[k];
      sel_valid[p] = |sel_onehot[p];
    end
  end

endmodule

`default_nettype wire
