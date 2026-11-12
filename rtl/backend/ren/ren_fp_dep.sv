// Ref: back-end/Ren.cpp  class Ren  Ren::comb_rename (F/D: same-cycle bypass inside the FP domain)
`default_nettype none

// FP version of ren_dep_check: four lookups per slot (src1, src2, src3, old destination) take the destination register
// of the nearest older slot of the group that writes the same FP register. f0 is a register: no special case.
module ren_fp_dep
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-2:0] producer,            // older slot is valid and writes an FP register (youngest: nobody's older)
  input  areg_t        dest_areg [N],
  input  areg_t        look_areg [N][4],    // src1, src2, src3, old destination
  input  preg_t        alloc_reg [N],       // FP register newly allocated to slot j
  input  preg_t        look_rat  [N][4],    // FP RAT lookups
  output preg_t        look_preg [N][4]
);

  for (genvar i = 0; i < N; i++) begin : g_slot
    for (genvar q = 0; q < 4; q++) begin : g_look
      logic [N-1:0] hit;
      logic         any_hit;
      preg_t        older [N];
      preg_t        value;
      for (genvar j = 0; j < N; j++) begin : g_older
        if (j < i) begin : g_yes
          assign older[j] = alloc_reg[j];
          assign hit[j]   = producer[j] & (look_areg[i][q] == dest_areg[j]);
        end else begin : g_no
          assign older[j] = '0;
          assign hit[j]   = 1'b0;
        end
      end
      ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_lw (.hit(hit), .data(older), .any(any_hit), .value(value));
      assign look_preg[i][q] = any_hit ? value : look_rat[i][q];
    end
  end

endmodule

`default_nettype wire
