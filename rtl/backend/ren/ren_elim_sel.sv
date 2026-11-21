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
  localparam int PW = N + 3;                    // {is_const, const_val, inv, root_oh[N-1:0]}

  logic [N-2:0] producer;                 // valid slot with a destination (the youngest is nobody's older slot)
  logic [N-1:0] cand, refs_ok;
  assign producer = inst_valid[N-2:0] & dest_en;
  assign cand     = inst_valid & move_shape;

  // Compute each slot's spec-RAT reference bound in parallel, and independently resolve each slot's
  // 1-hop intra-group bypass chain into a 1-bit affine function of at most one root slot's refs_ok:
  //   elim[i] = is_const_i ? const_val_i : ((|(root_oh_i & refs_ok)) ^ inv_i)
  // This keeps the bypass resolution off the slow 33-way spec_rat popcount critical path.
  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0] older, bypass_hit;
    logic [PW-1:0] parent_state [N];
    logic [PW-1:0] byp_state;
    logic          any_bypass;
    logic          is_const_i, const_val_i, inv_i;
    logic [N-1:0]  root_oh_i;
    logic [$clog2(N+1)-1:0] n_older;
    logic [RAT_NUM-1:0] ref_hit;
    logic [$clog2(RAT_NUM+1)-1:0] refs;
    logic [SW-1:0] total;

    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign older[j]      = producer[j];
        assign bypass_hit[j] = producer[j] & ~dest_fp[j] & (dest_areg[j] == src1_areg[i]);
        // 1-hop intra-group bypass: youngest older writer is a non-eliminated producer allocating a fresh preg
        // (0 prior RAT refs, at most i - j + 1 <= MOVE_ELIM_MAX_REFS refs in this group).
        if ((i - j) < MOVE_ELIM_MAX_REFS) begin : g_in_range
          assign parent_state[j] = {g_slot[j].is_const_i, ~g_slot[j].const_val_i, ~g_slot[j].inv_i, g_slot[j].root_oh_i};
        end else begin : g_oob
          assign parent_state[j] = {1'b1, 1'b0, 1'b0, {N{1'b0}}};
        end
      end else begin : g_no
        assign older[j]        = 1'b0;
        assign bypass_hit[j]   = 1'b0;
        assign parent_state[j] = '0;
      end
    end

    ren_last_write #(.N(N), .W(PW)) u_byp (
      .hit(bypass_hit), .data(parent_state), .any(any_bypass), .value(byp_state)
    );

    always_comb begin
      if (!cand[i]) begin
        is_const_i  = 1'b1;
        const_val_i = 1'b0;
        inv_i       = 1'b0;
        root_oh_i   = '0;
      end else if (!any_bypass) begin
        is_const_i  = 1'b0;
        const_val_i = 1'b0;
        inv_i       = 1'b0;
        root_oh_i   = N'(1) << i;
      end else begin
        {is_const_i, const_val_i, inv_i, root_oh_i} = byp_state;
      end
    end

    for (genvar e = 0; e < RAT_NUM; e++) begin : g_ref
      assign ref_hit[e] = (spec_rat[e] == src1_rat[i]);
    end
    ttg_popcount #(.N(N)) u_older (.bits(older), .count(n_older));
    ttg_popcount #(.N(RAT_NUM)) u_refs (.bits(ref_hit), .count(refs));
    assign total      = SW'(refs) + SW'(n_older);
    assign refs_ok[i] = (total < SW'(MOVE_ELIM_MAX_REFS));
  end

  for (genvar i = 0; i < N; i++) begin : g_out
    assign elim[i] = g_slot[i].is_const_i ? g_slot[i].const_val_i
                                          : ((|(g_slot[i].root_oh_i & refs_ok)) ^ g_slot[i].inv_i);
  end

endmodule

`default_nettype wire
