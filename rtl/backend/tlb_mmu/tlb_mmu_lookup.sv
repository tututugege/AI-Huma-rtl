// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::lookup_table_comb / entry_matches
`default_nettype none

// One lookup port: compare all entries in parallel, the lowest-index match wins (several entries can match after a
// page-table change
// without SFENCE, e.g. a 4 KiB entry inside a megapage), and the winner's translation is selected with a one-hot mux.
module tlb_mmu_lookup import tlb_mmu_pkg::*; #(
  parameter int ENTRIES = 64
) (
  input  logic [ENTRIES-1:0]     entry_valid,
  input  tlb_mmu_entry_t         entry [ENTRIES],
  input  logic [VPN_W-1:0]       vpn,
  input  logic [ASID_W-1:0]      asid,
  output logic                   hit,
  output tlb_mmu_xlat_t          xlat
);

  localparam int XLAT_W = $bits(tlb_mmu_xlat_t);

  logic [ENTRIES-1:0] match, match_first;
  logic [XLAT_W-1:0]  entry_xlat [ENTRIES];
  logic [XLAT_W-1:0]  xlat_bits;

  always_comb begin
    for (int i = 0; i < ENTRIES; i++) begin
      match[i] = entry_valid[i] && tag_match(entry[i].tag, vpn, asid);
      entry_xlat[i] = XLAT_W'(entry[i].xlat);
    end
  end

  ttg_first_set #(.N(ENTRIES)) u_first (.req(match), .onehot(match_first), .any(hit));
  ttg_onehot_mux #(.N(ENTRIES), .W(XLAT_W)) u_mux (.sel(match_first), .data(entry_xlat), .out(xlat_bits));

  assign xlat = tlb_mmu_xlat_t'(xlat_bits);

endmodule

`default_nettype wire
