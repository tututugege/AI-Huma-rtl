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
  input  areg_t        dest_areg [N],
  input  areg_t        src1_areg [N],
  input  preg_t        src1_rat [N],      // speculative RAT lookup of src1 (no group bypass)
  input  rat_t         spec_rat,
  output logic [N-1:0] elim
);

  localparam int SW = 8;                  // wide enough for RAT_NUM + N + 1

  logic [N-2:0] producer;                 // valid slot with a destination (the youngest is nobody's older slot)
  assign producer = inst_valid[N-2:0] & dest_en;

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0] older, bypass_hit;
    logic [$clog2(N+1)-1:0] n_older;
    logic [RAT_NUM-1:0] ref_hit;
    logic [$clog2(RAT_NUM+1)-1:0] refs;
    logic [SW-1:0] total;
    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign older[j]      = producer[j];
        assign bypass_hit[j] = producer[j] & (dest_areg[j] == src1_areg[i]);
      end else begin : g_no
        assign older[j]      = 1'b0;
        assign bypass_hit[j] = 1'b0;
      end
    end
    for (genvar e = 0; e < RAT_NUM; e++) begin : g_ref
      assign ref_hit[e] = (spec_rat[e] == src1_rat[i]);
    end
    ttg_popcount #(.N(N)) u_older (.bits(older), .count(n_older));
    ttg_popcount #(.N(RAT_NUM)) u_refs (.bits(ref_hit), .count(refs));
    assign total   = SW'(refs) + SW'(n_older) + SW'(1);
    assign elim[i] = inst_valid[i] & move_shape[i] & ~(|bypass_hit) & (total <= SW'(MOVE_ELIM_MAX_REFS));
  end

endmodule

`default_nettype wire
