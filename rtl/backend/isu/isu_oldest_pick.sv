// Ref: back-end/include/IssueQueue.h  IssueQueue::schedule (OLDEST_ON_FIRST_PORT: the oldest ready uop by ROB order, ties: lowest slot)
`default_nettype none

// The oldest candidate: a tournament tree over the slots. Ages are the {rob_flag, rob_idx} keys of the uops in flight (fewer than
// half the key range apart): a is older than b when (b - a) is non-zero and its top bit is clear (the model's cmp_inst_age).
// Equal keys (two uops of one instruction, an AMO's LD and STA) go to the lower slot.
module isu_oldest_pick #(
  parameter int N  = 64,
  parameter int KW = 8
) (
  input  logic [N-1:0]  cand,
  input  logic [KW-1:0] key [N],
  output logic [N-1:0]  onehot,
  output logic          any
);

  localparam int LEVELS = (N > 1) ? $clog2(N) : 1;
  localparam int IW     = (N > 1) ? $clog2(N) : 1;
  localparam int NP2    = 1 << LEVELS;                  // leaves rounded up to a power of two

  logic          v [LEVELS+1][NP2];
  logic [KW-1:0] k [LEVELS+1][NP2];
  logic [IW-1:0] w [LEVELS+1][NP2];                     // slot of the winner

  always_comb begin
    for (int i = 0; i < NP2; i++) begin
      v[0][i] = (i < N) ? cand[i] : 1'b0;
      k[0][i] = (i < N) ? key[i] : '0;
      w[0][i] = IW'(i);
    end
    for (int l = 0; l < LEVELS; l++) begin
      for (int i = 0; i < (NP2 >> (l + 1)); i++) begin
        logic [KW-1:0] dr;
        logic          r_older;                         // the right child is strictly older than the left one
        dr = k[l][2*i] - k[l][2*i+1];                   // left - right: the right child is older iff this is non-zero with the top bit clear
        r_older = (dr != '0) && !dr[KW-1];
        if (!v[l][2*i])            begin v[l+1][i] = v[l][2*i+1]; k[l+1][i] = k[l][2*i+1]; w[l+1][i] = w[l][2*i+1]; end
        else if (!v[l][2*i+1])     begin v[l+1][i] = 1'b1;        k[l+1][i] = k[l][2*i];   w[l+1][i] = w[l][2*i];   end
        else if (r_older)          begin v[l+1][i] = 1'b1;        k[l+1][i] = k[l][2*i+1]; w[l+1][i] = w[l][2*i+1]; end
        else                       begin v[l+1][i] = 1'b1;        k[l+1][i] = k[l][2*i];   w[l+1][i] = w[l][2*i];   end
      end
    end
    any = v[LEVELS][0];
    for (int i = 0; i < N; i++) onehot[i] = any && (w[LEVELS][0] == IW'(i));
  end

endmodule

`default_nettype wire
