// Ref: MemSubSystem/include/MemPtwBlock.h  MemPtwBlock::on_walk_mem_resp (PTE checks)
`default_nettype none

// Page-table-entry classification of the walker.  Only V/R/W/X and the PPN are examined (A/D/U permissions are
// the TLB's business).  level1 = the PTE came from the first-level read.
//   level 1: invalid or R=0,W=1 -> fault; R|X -> superpage leaf (fault if ppn[9:0] != 0); else next-level pointer
//   level 0: invalid or R=0,W=1 or not (R|X) -> fault; else leaf
module ptw_walk_pte import memcpu_pkg::*; (
  input  logic [31:0] pte,
  input  logic        level1,
  output logic        fault,
  output logic        pointer,   // level 1 only: next-level table pointer
  output logic        leaf,
  output logic [PT_PPN_W-1:0]  ppn,    // pte[29:10]
  output logic [PT_PERM_W-1:0] perm    // pte[7:0]
);

  /* verilator lint_off UNUSEDSIGNAL */  // pte[31:30] (ppn[21:20]) and pte[9:8] (RSW) never influence a walk
  wire [31:0] pte_w = pte;
  /* verilator lint_on UNUSEDSIGNAL */
  wire v = pte_w[0];
  wire r = pte_w[1];
  wire w = pte_w[2];
  wire x = pte_w[3];
  wire reserved    = !v || (!r && w);
  wire is_leaf_enc = r || x;
  wire misaligned  = (pte_w[19:10] != 10'd0);

  always_comb begin
    fault   = 1'b0;
    pointer = 1'b0;
    leaf    = 1'b0;
    if (reserved) begin
      fault = 1'b1;
    end else if (level1) begin
      if (is_leaf_enc) begin
        fault = misaligned;
        leaf  = !misaligned;
      end else begin
        pointer = 1'b1;
      end
    end else begin
      fault = !is_leaf_enc;
      leaf  = is_leaf_enc;
    end
  end

  assign ppn  = pte_w[29:10];
  assign perm = pte_w[7:0];

endmodule

`default_nettype wire
