// Shared IEEE-754 F/D helper functions and rounding primitives for synthesizable FPU units.
`default_nettype none
package fp_arith_pkg;

  localparam logic [31:0] CANON_NAN32 = 32'h7fc0_0000;
  localparam logic [63:0] CANON_NAN64 = 64'h7ff8_0000_0000_0000;

  // fflags bit positions (RISC-V spec): [4]=NV, [3]=DZ, [2]=OF, [1]=UF, [0]=NX
  localparam int FLG_NX = 0;
  localparam int FLG_UF = 1;
  localparam int FLG_OF = 2;
  localparam int FLG_DZ = 3;
  localparam int FLG_NV = 4;

  // Resolve dynamic rounding mode (func3 == 3'd7 -> frm); valid iff rm <= 4
  function automatic logic [2:0] fp_resolve_rm(input logic [2:0] func3, input logic [2:0] frm);
    return (func3 == 3'd7) ? frm : func3;
  endfunction

  function automatic logic fp_rm_valid(input logic [2:0] rm);
    return (rm <= 3'd4);
  endfunction

  // NaN-boxing helpers
  function automatic logic [63:0] fp_nanbox32(input logic [31:0] v);
    return {32'hffff_ffff, v};
  endfunction

  function automatic logic [31:0] fp_unbox32(input logic [63:0] v);
    return (&v[63:32]) ? v[31:0] : CANON_NAN32;
  endfunction

  // IEEE-754 rounding increment decision for magnitude (sign, lsb, guard, round/sticky):
  //   rm=0 RNE: g & (r | s | lsb)
  //   rm=1 RTZ: 0
  //   rm=2 RDN: sign & (g | r | s)
  //   rm=3 RUP: ~sign & (g | r | s)
  //   rm=4 RMM: g
  function automatic logic fp_round_inc(
    input logic [2:0] rm,
    input logic       sign,
    input logic       lsb,
    input logic       g,
    input logic       s
  );
    case (rm)
      3'd0:    return g & (s | lsb);
      3'd1:    return 1'b0;
      3'd2:    return sign & (g | s);
      3'd3:    return (~sign) & (g | s);
      3'd4:    return g;
      default: return 1'b0;
    endcase
  endfunction

  // 64-bit leading-zero count (balanced binary tree, O(log N) depth)
  function automatic logic [6:0] clz64(input logic [63:0] x);
    logic [6:0]  cnt;
    logic [31:0] v32;
    logic [15:0] v16;
    logic [7:0]  v8;
    logic [3:0]  v4;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0]  v2;
    /* verilator lint_on UNUSEDSIGNAL */
    if (x == 64'd0) return 7'd64;
    cnt = 7'd0;
    if (x[63:32] == 32'd0) begin cnt[5] = 1'b1; v32 = x[31:0];  end else begin cnt[5] = 1'b0; v32 = x[63:32]; end
    if (v32[31:16] == 16'd0) begin cnt[4] = 1'b1; v16 = v32[15:0]; end else begin cnt[4] = 1'b0; v16 = v32[31:16]; end
    if (v16[15:8]  == 8'd0)  begin cnt[3] = 1'b1; v8  = v16[7:0];  end else begin cnt[3] = 1'b0; v8  = v16[15:8];  end
    if (v8[7:4]    == 4'd0)  begin cnt[2] = 1'b1; v4  = v8[3:0];   end else begin cnt[2] = 1'b0; v4  = v8[7:4];    end
    if (v4[3:2]    == 2'd0)  begin cnt[1] = 1'b1; v2  = v4[1:0];   end else begin cnt[1] = 1'b0; v2  = v4[3:2];    end
    cnt[0] = ~v2[1];
    return cnt;
  endfunction

endpackage
`default_nettype wire
