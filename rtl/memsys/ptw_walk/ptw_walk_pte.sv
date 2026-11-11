// Ref: MemSubSystem/include/MemPtwBlock.h  on_walk_mem_resp (PTE classification)
`default_nettype none

// Classify the PTE read at `level` (Sv32: 1, 0; Sv39: 2, 1, 0): fault (invalid / W without R / Sv39 reserved bits / a
// misaligned superpage / a pointer at level 0), next-level pointer, or leaf.  Only ppn[19:0] reaches the 32-bit
// physical address; perm = pte[7:0].
module ptw_walk_pte import memcpu_pkg::*; import ttg_cfg_pkg::*; (
  input  logic [XLEN_BITS-1:0] pte,
  input  logic [PT_LVL_W-1:0]  level,
  output logic                 fault,
  output logic                 pointer,   // next-level table pointer
  output logic                 leaf,
  output logic [PT_PPN_W-1:0]  ppn,       // pte[29:10]
  output logic [PT_PERM_W-1:0] perm       // pte[7:0]
);

  /* verilator lint_off UNUSEDSIGNAL */  // the high ppn bits (they would exceed the 32-bit physical space) and RSW
  wire [63:0] pte_w = 64'(pte);
  /* verilator lint_on UNUSEDSIGNAL */
  wire v = pte_w[0];
  wire r = pte_w[1];
  wire w = pte_w[2];
  wire x = pte_w[3];
  // Sv39: bits 63:54 are reserved (Svnapot / Svpbmt are not implemented)
  wire rsvd_hi     = (XLEN_BITS == 64) && (pte_w[63:54] != 10'd0);
  wire reserved    = !v || (!r && w) || rsvd_hi;
  wire is_leaf_enc = r || x;
  // the ppn bits below a superpage's level must be zero
  logic misaligned;
  always_comb begin
    misaligned = 1'b0;
    for (int k = 1; k < PT_LEVELS; k++)
      for (int b = 0; b < PT_VPN_PART_W; b++)
        if (k <= int'(level) && b + PT_VPN_PART_W * (k - 1) < PT_PPN_W && pte_w[10 + PT_VPN_PART_W * (k - 1) + b])
          misaligned = 1'b1;
  end

  always_comb begin
    fault   = 1'b0;
    pointer = 1'b0;
    leaf    = 1'b0;
    if (reserved) begin
      fault = 1'b1;
    end else if (is_leaf_enc) begin
      fault = misaligned;
      leaf  = !misaligned;
    end else if (level == '0) begin
      fault = 1'b1;
    end else begin
      pointer = 1'b1;
    end
  end

  assign ppn  = pte_w[29:10];
  assign perm = pte_w[7:0];

endmodule

`default_nettype wire
