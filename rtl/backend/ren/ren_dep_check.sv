// Ref: back-end/Ren.cpp  class Ren  Ren::comb_rename (same-cycle RAW/WAW bypass)
`default_nettype none

// Within one rename group, a source/old-dest that names the same areg as an older slot's destination takes that
// slot's destination preg instead of the RAT value; the nearest older writer wins. (The decoder never sets
// dest_en for x0, so no x0 special case is needed.) The destination preg of a slot is its newly allocated register,
// or, for an eliminated move, its (already bypassed) source register: dest_preg_out.
module ren_dep_check
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-2:0] inst_valid,   // the youngest slot never produces for an older one
  input  logic [N-1:0] raw_hit_dest [N],    // pre-decoded in S1: dest_en[j] & ~dest_fp[j] & (dest_areg[i]==dest_areg[j])
  input  logic [N-1:0] raw_hit_src1 [N],
  input  logic [N-1:0] raw_hit_src2 [N],
  input  preg_t        alloc_reg [N],       // preg newly allocated to slot j (0 if none)
  input  logic [N-1:0] elim,                // slot is an eliminated move: its destination is its source register
  input  preg_t        dest_normal [N],     // RAT lookups (old_dest, src1, src2)
  input  preg_t        src1_normal [N],
  input  preg_t        src2_normal [N],
  output preg_t        old_dest_preg [N],
  output preg_t        src1_preg [N],
  output preg_t        src2_preg [N],
  output preg_t        dest_preg_out [N]    // final destination register of each slot
);

  // Two-level non-recursive bypass (reuses ttg_first_set + ttg_onehot_mux):
  // Level 1: compute every slot's final destination preg in parallel with zero cross-lane chaining.
  //   ren_elim_sel guarantees 1-hop elimination: whenever elim[i] == 1 and an older producer j writes src1_areg[i],
  //   the youngest such j has elim[j] == 0, so its destination is alloc_reg[j]. Thus dest_of[i] depends only on
  //   alloc_reg[0..i-1] and src1_normal[i], breaking the 7-hop structural chain across lanes.
  // Level 2: bypass old_dest / src1 / src2 from dest_of[0..i-1] in parallel (reusing src1's ttg_first_set).
  preg_t        dest_of [N];
  preg_t        alloc_rev [N];
  preg_t        dest_of_rev [N];
  for (genvar k = 0; k < N; k++) begin : g_rev
    assign alloc_rev[k]   = alloc_reg[N-1-k];
    assign dest_of_rev[k] = dest_of[N-1-k];
  end

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0] hit_dest, hit_src1, hit_src2;
    logic [N-1:0] hit_src1_rev, pick_src1_rev;
    logic         any_dest, any_src1, any_src2;
    preg_t        val_dest, val_src1_alloc, val_src1, val_src2;
    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign hit_dest[j] = inst_valid[j] & raw_hit_dest[i][j];
        assign hit_src1[j] = inst_valid[j] & raw_hit_src1[i][j];
        assign hit_src2[j] = inst_valid[j] & raw_hit_src2[i][j];
      end else begin : g_no
        assign hit_dest[j] = 1'b0;
        assign hit_src1[j] = 1'b0;
        assign hit_src2[j] = 1'b0;
      end
      assign hit_src1_rev[j] = hit_src1[N-1-j];
    end

    // Shared priority select for src1 (highest-index older hit wins)
    ttg_first_set  #(.N(N))                    u_src1_pick  (.req(hit_src1_rev),  .onehot(pick_src1_rev), .any(any_src1));
    // Level 1: 1-hop destination preg (zero cross-lane dependency)
    ttg_onehot_mux #(.N(N), .W(PRF_IDX_WIDTH)) u_src1_alloc (.sel(pick_src1_rev), .data(alloc_rev),       .out(val_src1_alloc));
    assign dest_of[i]       = elim[i] ? (any_src1 ? val_src1_alloc : src1_normal[i]) : alloc_reg[i];

    // Level 2: final source and old-dest bypass from dest_of[0..i-1]
    ttg_onehot_mux #(.N(N), .W(PRF_IDX_WIDTH)) u_src1_mux   (.sel(pick_src1_rev), .data(dest_of_rev),     .out(val_src1));
    ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_dest       (.hit(hit_dest),      .data(dest_of),         .any(any_dest), .value(val_dest));
    ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_src2       (.hit(hit_src2),      .data(dest_of),         .any(any_src2), .value(val_src2));

    assign old_dest_preg[i] = any_dest ? val_dest : dest_normal[i];
    assign src1_preg[i]     = any_src1 ? val_src1 : src1_normal[i];
    assign src2_preg[i]     = any_src2 ? val_src2 : src2_normal[i];
    assign dest_preg_out[i] = dest_of[i];
  end

endmodule

`default_nettype wire
