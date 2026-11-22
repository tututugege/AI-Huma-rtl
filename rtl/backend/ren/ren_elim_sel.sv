// Ref: back-end/Ren.cpp  class Ren  Ren::elim_refs_ok (move elimination: which moves are renamed away)
`default_nettype none

// A move-shaped instruction is eliminated when its source register comes straight from the speculative RAT (no older
// instruction of the group writes the source's architectural register) and the reference bound holds:
//   (spec RAT entries naming the source) + (older valid instructions of the group with a destination) + 1
//     <= MOVE_ELIM_MAX_REFS.
// The architectural state after a move commits equals the speculative RAT right after its rename, so the architectural
// reference counters (CNT_W bits) can never exceed the bound; older writers add at most one reference each.
module ren_elim_sel
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-1:0] inst_valid,
  input  logic [N-1:0] move_shape,        // addi rd, rs, 0 with real rd and rs
  input  logic [N-2:0] dest_en,           // the youngest slot is nobody's older slot
  input  logic [N-2:0] dest_fp,           // older slot's destination is an FP register (does not bypass an INT source)
  input  areg_t        dest_areg [N],
  input  areg_t        src1_areg [N],
  input  preg_t        src1_rat [N],      // speculative RAT lookup of src1 (no group bypass)
  input  rat_t         spec_rat,
  output logic [N-1:0] elim
);

  localparam int SW = $clog2(RAT_NUM + N + 1);  // wide enough for RAT_NUM + N (6 bits for 33 + 8 = 41)
  localparam int NW = $clog2(N);                // 3 bits for N = 8
  localparam int ST = NW;                       // ceil(log2(N)) = 3 pointer-jumping stages cover up to 2^3 = 8 hops

  logic [N-2:0] producer;                 // valid slot with a destination (the youngest is nobody's older slot)
  logic [N-1:0] cand, refs_ok;
  assign producer = inst_valid[N-2:0] & dest_en;
  assign cand     = inst_valid & move_shape;

  // Stage 0..ST pointer-jumping state for each lane:
  //   is_const=1 -> elim[i] = const_val
  //   is_const=0 -> elim[i] = refs_ok[ptr] ^ inv (once pointer jumping reaches root ptr[0][root] == root)
  // Using a 3-stage Kogge-Stone doubling network collapses the 7-hop serial bypass chain into 3 parallel levels,
  // completely in parallel with the 33-way spec_rat ttg_popcount.
  logic [N-1:0]  st_const     [ST+1];
  logic [N-1:0]  st_cval      [ST+1];
  logic [N-1:0]  st_inv       [ST+1];
  logic [NW-1:0] st_ptr       [ST+1][N];

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0] older, bypass_hit, bypass_rev, pick_rev, pick;
    logic         any_bypass;
    logic [NW-1:0] prod_idx;
    logic [$clog2(N+1)-1:0] n_older;
    logic [RAT_NUM-1:0] ref_hit;
    logic [$clog2(RAT_NUM+1)-1:0] refs;
    logic [SW-1:0] total;
    logic          in_range;

    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign older[j]      = producer[j];
        assign bypass_hit[j] = producer[j] & ~dest_fp[j] & (dest_areg[j] == src1_areg[i]);
      end else begin : g_no
        assign older[j]      = 1'b0;
        assign bypass_hit[j] = 1'b0;
      end
      assign bypass_rev[j] = bypass_hit[N-1-j];
      assign pick[j]       = pick_rev[N-1-j];
    end

    ttg_first_set     #(.N(N)) u_byp_pick (.req(bypass_rev), .onehot(pick_rev), .any(any_bypass));
    ttg_onehot_to_idx #(.N(N)) u_byp_idx  (.onehot(pick),    .idx(prod_idx));

    // 1-hop intra-group bypass allowed only when (i - prod_idx) < MOVE_ELIM_MAX_REFS
    assign in_range = ((NW+1)'(i) - (NW+1)'(prod_idx)) < (NW+1)'(MOVE_ELIM_MAX_REFS);

    always_comb begin
      if (!cand[i]) begin
        st_const[0][i] = 1'b1;
        st_cval[0][i]  = 1'b0;
        st_inv[0][i]   = 1'b0;
        st_ptr[0][i]   = NW'(i);
      end else if (!any_bypass) begin
        st_const[0][i] = 1'b0;
        st_cval[0][i]  = 1'b0;
        st_inv[0][i]   = 1'b0;
        st_ptr[0][i]   = NW'(i);
      end else if (!in_range) begin
        st_const[0][i] = 1'b1;
        st_cval[0][i]  = 1'b0;
        st_inv[0][i]   = 1'b0;
        st_ptr[0][i]   = NW'(i);
      end else begin
        st_const[0][i] = 1'b0;
        st_cval[0][i]  = 1'b0;
        st_inv[0][i]   = 1'b1;
        st_ptr[0][i]   = prod_idx;
      end
    end

    for (genvar e = 0; e < RAT_NUM; e++) begin : g_ref
      assign ref_hit[e] = (spec_rat[e] == src1_rat[i]);
    end
    ttg_popcount #(.N(N))       u_older (.bits(older),   .count(n_older));
    ttg_popcount #(.N(RAT_NUM)) u_refs  (.bits(ref_hit), .count(refs));
    assign total      = SW'(refs) + SW'(n_older);
    assign refs_ok[i] = (total < SW'(MOVE_ELIM_MAX_REFS));
  end

  // 3-stage parallel pointer jumping (each stage doubles reach: 1 -> 2 -> 4 -> 8)
  localparam int PW = 3 + NW;   // {is_const, cval, inv, ptr}
  for (genvar s = 0; s < ST; s++) begin : g_jump
    logic [PW-1:0] cur_packed [N];
    for (genvar k = 0; k < N; k++) begin : g_pack
      assign cur_packed[k] = {st_const[s][k], st_cval[s][k], st_inv[s][k], st_ptr[s][k]};
    end
    for (genvar i = 0; i < N; i++) begin : g_lane
      logic [N-1:0]  p_oh;
      logic [PW-1:0] p_data;
      logic          p_const, p_cval, p_inv;
      logic [NW-1:0] p_ptr;
      for (genvar k = 0; k < N; k++) begin : g_dec
        assign p_oh[k] = (st_ptr[s][i] == NW'(k));
      end
      ttg_onehot_mux #(.N(N), .W(PW)) u_pmux (.sel(p_oh), .data(cur_packed), .out(p_data));
      assign {p_const, p_cval, p_inv, p_ptr} = p_data;

      logic hold;
      assign hold             = st_const[s][i] || (st_ptr[s][i] == NW'(i));
      assign st_const[s+1][i] = hold ? st_const[s][i] : p_const;
      assign st_cval[s+1][i]  = hold ? st_cval[s][i]  : (p_cval ^ st_inv[s][i]);
      assign st_inv[s+1][i]   = hold ? st_inv[s][i]   : (st_inv[s][i] ^ p_inv);
      assign st_ptr[s+1][i]   = hold ? st_ptr[s][i]   : p_ptr;
    end
  end

  for (genvar i = 0; i < N; i++) begin : g_out
    logic [N-1:0] root_oh;
    logic         root_ok;
    for (genvar k = 0; k < N; k++) begin : g_roh
      assign root_oh[k] = (st_ptr[ST][i] == NW'(k));
    end
    assign root_ok = |(root_oh & refs_ok);
    assign elim[i] = st_const[ST][i] ? st_cval[ST][i] : (root_ok ^ st_inv[ST][i]);
  end

endmodule

`default_nettype wire
