// Ref: back-end/Ren.cpp  class Ren  Ren::elim_refs_ok (move elimination: which moves are renamed away)
`default_nettype none

// Move elimination with 6-bit unbounded arch_cnt (max RAT_NUM = 33, never overflows):
// a move-shaped instruction is eliminated unless its source is written by an older eliminated move in the same group
// (1-hop intra-group bypass). Uses pre-decoded S1 raw_hit_src1 so elim[0..N-1] is completely independent of spec_RAT!
module ren_elim_sel
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-1:0] inst_valid,
  input  logic [N-1:0] move_shape,          // addi rd, rs, 0 with real rd and rs (pre-decoded in S1)
  input  logic [N-1:0] raw_hit_src1 [N],    // pre-decoded in S1: dest_en[j] & ~dest_fp[j] & (dest_areg[j]==src1_areg[i])
  output logic [N-1:0] elim
);

  localparam int NW = $clog2(N);  // 3 bits for N = 8
  localparam int ST = NW;         // ceil(log2(N)) = 3 pointer-jumping stages cover up to 2^3 = 8 hops

  logic [N-1:0] cand;
  assign cand = inst_valid & move_shape;

  // Stage 0..ST pointer-jumping state for each lane:
  //   st_const=1 -> elim[i] = st_cval
  //   st_const=0 -> elim[i] = elim[st_ptr] ^ st_inv
  // Every chain terminates at a lane with st_const=1 (either !cand or !any_bypass -> cval=1).
  logic [N-1:0]  st_const [ST+1];
  logic [N-1:0]  st_cval  [ST+1];
  logic [N-1:0]  st_inv   [ST+1];
  logic [NW-1:0] st_ptr   [ST+1][N];

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0]  bypass_hit, bypass_rev, pick_rev, pick;
    logic          any_bypass;
    logic [NW-1:0] prod_idx;

    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign bypass_hit[j] = inst_valid[j] & raw_hit_src1[i][j];
      end else begin : g_no
        assign bypass_hit[j] = 1'b0;
      end
      assign bypass_rev[j] = bypass_hit[N-1-j];
      assign pick[j]       = pick_rev[N-1-j];
    end

    ttg_first_set     #(.N(N)) u_byp_pick (.req(bypass_rev), .onehot(pick_rev), .any(any_bypass));
    ttg_onehot_to_idx #(.N(N)) u_byp_idx  (.onehot(pick),    .idx(prod_idx));

    always_comb begin
      if (!cand[i]) begin
        st_const[0][i] = 1'b1;
        st_cval[0][i]  = 1'b0;
        st_inv[0][i]   = 1'b0;
        st_ptr[0][i]   = NW'(i);
      end else if (!any_bypass) begin
        st_const[0][i] = 1'b1;
        st_cval[0][i]  = 1'b1;
        st_inv[0][i]   = 1'b0;
        st_ptr[0][i]   = NW'(i);
      end else begin
        st_const[0][i] = 1'b0;
        st_cval[0][i]  = 1'b0;
        st_inv[0][i]   = 1'b1;
        st_ptr[0][i]   = prod_idx;
      end
    end
  end

  // Pointer-jumping doubling: ST = log2(N) parallel stages resolve all intra-group chains
  for (genvar s = 0; s < ST; s++) begin : g_jump
    for (genvar i = 0; i < N; i++) begin : g_lane
      logic [NW-1:0] p;
      assign p               = st_ptr[s][i];
      assign st_const[s+1][i] = st_const[s][i] ? 1'b1 : st_const[s][p];
      assign st_cval[s+1][i]  = st_const[s][i] ? st_cval[s][i]
                              : (st_const[s][p] ? (st_cval[s][p] ^ st_inv[s][i]) : 1'b0);
      assign st_inv[s+1][i]   = (st_const[s][i] | st_const[s][p]) ? 1'b0 : (st_inv[s][i] ^ st_inv[s][p]);
      assign st_ptr[s+1][i]   = (st_const[s][i] | st_const[s][p]) ? p : st_ptr[s][p];
    end
  end

  for (genvar i = 0; i < N; i++) begin : g_out
    assign elim[i] = st_cval[ST][i];
  end

endmodule

`default_nettype wire
