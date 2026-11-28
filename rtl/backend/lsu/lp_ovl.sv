// Ref: back-end/Lsu/RealLsuPipe.cpp  range_rel(...) != DISJOINT (load [lo, lo+lw) vs store [so, so+sw), no wrap)
`default_nettype none

// Overlap of a load and a store range on W address bits, log-depth: with d = so - lo they overlap iff -sw < d < lw.
// Split into the byte-in-8 part (3 bits) and the upper part: |d| < 8 needs the upper parts to be equal or to differ
// by exactly one, which is an equality / "a == b + 1" test (no carry chain on the late side).  The byte-in-8 part is
// lp_pkg::rel_ovl, shared with rel12 / rel32_pre_* (ovl == (rel != 0)).
module lp_ovl import lp_pkg::rel_ovl; #(
  parameter int W = 12
) (
  input  logic [W-1:0] lo,
  input  logic [2:0]   lf,
  input  logic [W-1:0] so,
  input  logic [2:0]   sf,
  output logic         ovl
);

  localparam int U = W - 3;
  logic [U-1:0] ul, us, us_p, us_m;
  logic         eq0, s_is_l1, l_is_s1;

  // The load side (lo, lf) arrives late, the store side (so, sf) is a register: compare the load's upper part with the
  // store's upper part and with its neighbours (us + 1, us - 1, computed from the store side alone), three parallel
  // equality tests with no prefix chain on the late side.
  always_comb begin
    ul = lo[W-1:3];
    us = so[W-1:3];
    us_p = us + U'(1);
    us_m = us - U'(1);
    eq0 = (ul == us);
    s_is_l1 = (ul == us_m) && (us != '0);       // us == ul + 1 (no wrap of the upper part)
    l_is_s1 = (ul == us_p) && !(&us);           // ul == us + 1
    ovl = rel_ovl(eq0, s_is_l1, l_is_s1, lo[2:0], lf, so[2:0], sf);
  end

endmodule

`default_nettype wire
