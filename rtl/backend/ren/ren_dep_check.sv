// Ref: back-end/Ren.cpp  class Ren  Ren::comb_rename (same-cycle RAW/WAW bypass)
`default_nettype none

// Within one rename group, a source/old-dest that names the same areg as an older slot's destination takes that
// slot's newly allocated preg instead of the RAT value; the nearest older writer wins. (The decoder never sets
// dest_en for x0, so no x0 special case is needed.)
module ren_dep_check
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-2:0] inst_valid,   // the youngest slot never produces for an older one
  input  logic [N-2:0] dest_en,
  input  areg_t        dest_areg [N],
  input  areg_t        src1_areg [N],
  input  areg_t        src2_areg [N],
  input  preg_t        alloc_reg [N],       // preg newly allocated to slot j (0 if none)
  input  preg_t        dest_normal [N],     // RAT lookups (old_dest, src1, src2)
  input  preg_t        src1_normal [N],
  input  preg_t        src2_normal [N],
  output preg_t        old_dest_preg [N],
  output preg_t        src1_preg [N],
  output preg_t        src2_preg [N]
);

  // older slot j can be bypassed from: valid and writes a register
  logic [N-2:0] producer;     // the youngest slot is never an older producer
  for (genvar j = 0; j < N - 1; j++) begin : g_prod
    assign producer[j] = inst_valid[j] & dest_en[j];
  end

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [N-1:0] hit_dest, hit_src1, hit_src2;
    logic         any_dest, any_src1, any_src2;
    preg_t        val_dest, val_src1, val_src2;
    for (genvar j = 0; j < N; j++) begin : g_older
      if (j < i) begin : g_yes
        assign hit_dest[j] = producer[j] & (dest_areg[i] == dest_areg[j]);
        assign hit_src1[j] = producer[j] & (src1_areg[i] == dest_areg[j]);
        assign hit_src2[j] = producer[j] & (src2_areg[i] == dest_areg[j]);
      end else begin : g_no
        assign hit_dest[j] = 1'b0;
        assign hit_src1[j] = 1'b0;
        assign hit_src2[j] = 1'b0;
      end
    end
    ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_dest (.hit(hit_dest), .data(alloc_reg), .any(any_dest),
                                                       .value(val_dest));
    ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_src1 (.hit(hit_src1), .data(alloc_reg), .any(any_src1),
                                                       .value(val_src1));
    ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_src2 (.hit(hit_src2), .data(alloc_reg), .any(any_src2),
                                                       .value(val_src2));
    assign old_dest_preg[i] = any_dest ? val_dest : dest_normal[i];
    assign src1_preg[i]     = any_src1 ? val_src1 : src1_normal[i];
    assign src2_preg[i]     = any_src2 ? val_src2 : src2_normal[i];
  end

endmodule

`default_nettype wire
