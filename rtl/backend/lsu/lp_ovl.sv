// Ref: back-end/Lsu/RealLsuPipe.cpp  range_rel(...) != DISJOINT (load [lo, lo+lw) vs store [so, so+sw), no wrap)
`default_nettype none

// Overlap of a load and a store range on W address bits, log-depth: with d = so - lo they overlap iff -sw < d < lw
// (accesses of 1, 2 or 4 bytes).  Split into the byte-in-8 part (3 bits) and the upper part: |d| < 5 needs the upper
// parts to be equal or to differ by exactly one, which is an equality / "a == b + 1" test (prefix-AND, no carry chain).
// Tested exhaustively-random against rel12 / rel32 (lp_pkg).
module lp_ovl import ttg_cfg_pkg::*; #(
  parameter int W = 12
) (
  input  logic [W-1:0] lo,
  /* verilator lint_off UNUSEDSIGNAL */  // func3[2] (sign) is not used
  input  logic [2:0]   lf,
  input  logic [W-1:0] so,
  input  logic [2:0]   sf,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic         ovl
);

  localparam int U = W - 3;
  logic [U-1:0] ul, us, us_p, us_m;
  logic         eq0, s_is_l1, l_is_s1;
  logic signed [5:0] dl, lw, sw;
  logic         c0, c1, cm;

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
    lw = $signed({2'b00, ld_w(lf[1:0])});
    sw = $signed({2'b00, ld_w(sf[1:0])});
    dl = $signed({3'b000, so[2:0]}) - $signed({3'b000, lo[2:0]});
    c0 = (dl > -sw) && (dl < lw);        // same 8-byte block
    c1 = (dl + 6'sd8 < lw);              // store block one higher: d = 8 + dl > 0
    cm = (dl - 6'sd8 > -sw);             // store block one lower: d = dl - 8 < 0
    ovl = (eq0 && c0) || (s_is_l1 && !eq0 && c1) || (l_is_s1 && !eq0 && cm);
  end

  function automatic logic [3:0] ld_w(input logic [1:0] f);   // func3[1:0]: 1, 2, 4 (8 on rv64) bytes
    case (f)
      2'b00:   return 4'd1;
      2'b01:   return 4'd2;
      2'b10:   return 4'd4;
      default: return 4'd8;
    endcase
  endfunction

endmodule

`default_nettype wire
