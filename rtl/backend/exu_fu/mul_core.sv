// Ref: back-end/Exu/include/Fu.h  MulUnit::impl_compute (mul / mulh / mulhsu / mulhu, and rv64 mulw)
`default_nettype none

// XLENxXLEN multiplier spread over MUL_MAX_LATENCY = 3 cycles from the accept cycle to the result:
//   accept cycle t : operands (sign / zero extended by func3) -> registers a_q, b_q
//   t + 1          : 2*XLEN-bit product of registered operands as carry-save (sum_q + car_q)
//   t + 2 (result) : carry-propagate add and half select (mul / mulh* / mulw), comb to output
// The result is valid in cycle t + 2 only: mul_pipe completes the entry exactly then, and the
// write-back reservation of ISU guarantees consumption in that cycle (checked in sim by mul_unit).
//   func3[1:0]: 0 mul (low half) 1 mulh (signed x signed) 2 mulhsu (signed x unsigned) 3 mulhu (unsigned x unsigned).
//   rv64 mulw (is_word, func3 = 0): the low word of the product, sign-extended.
// STRUCT = 0: `a * b` (fast sim); STRUCT = 1: Radix-4 Booth (33 partial products + 1 sign/hot-1 row = 34 rows,
// halved from 68) + explicit Wallace 3:2 compressor tree + Kogge-Stone final adder.
// Default: structural for synthesis (SYNTHESIS defined), behavioural for sim (scripts/mul_check.sh compares them).
module mul_core
  import ttg_cfg_pkg::*;
#(
`ifdef SYNTHESIS
  parameter bit STRUCT = 1'b1
`else
  parameter bit STRUCT = 1'b0
`endif
) (
  input  logic        clk,
  input  logic [1:0]  func3,
  input  logic        is_word,
  input  logic [XLEN_BITS-1:0] src1_rdata,
  input  logic [XLEN_BITS-1:0] src2_rdata,
  output logic [XLEN_BITS-1:0] result          // the result of the operands given 2 cycles ago
);

  localparam int W  = XLEN_BITS;
  localparam int HW = XLEN_BITS / 2;
  localparam int PW = 2 * W;               // product bits that are used
  localparam int AW = W + 1;               // operand width with the sign / zero extension bit
  localparam int NB = (AW + 1) / 2;        // Radix-4 Booth groups: 33 for 65-bit operands
  localparam int MW = AW + 2;              // signed width of +/-2*a (67 bits: no overflow for any AW-bit signed a)
  localparam int NC = NB + 1;              // rows of the tree: NB Booth partial products + 1 (CONST_FIX | hot-1 negs)

  function automatic int rows_next(input int n);
    return 2 * (n / 3) + (n % 3);
  endfunction
  function automatic int num_levels();
    int n = NC, l = 0;
    for (int i = 0; i < NC; i++) if (n > 2) begin n = rows_next(n); l++; end
    return l;
  endfunction
  localparam int NL = num_levels();

  function automatic logic [PW-1:0] booth_const_fix();
    logic [PW-1:0] c;
    c = '0;
    for (int j = 0; j < NB; j++) begin
      if (MW + 2 * j < PW) c = c - (PW'(1) << (MW + 2 * j));
    end
    return c;
  endfunction
  localparam logic [PW-1:0] CONST_FIX = booth_const_fix();

  // ---- t: operand extension, registered ----
  logic               a_signed, b_signed;
  logic [AW-1:0]      a_ext, b_ext;
  always_comb begin
    a_signed = (func3 == 2'd1) || (func3 == 2'd2);   // mulh, mulhsu: signed rs1 (mul: low half is sign agnostic)
    b_signed = (func3 == 2'd1);                      // mulh: signed rs2
    a_ext    = {a_signed && src1_rdata[W-1], src1_rdata};
    b_ext    = {b_signed && src2_rdata[W-1], src2_rdata};
  end

  logic [AW-1:0] a_q, b_q;
  logic [1:0]    f3_q, f3_s2_q;
  logic          wd_q, wd_s2_q;
  always_ff @(posedge clk) begin
    a_q  <= a_ext;
    b_q  <= b_ext;
    f3_q <= func3;
    wd_q <= is_word;
  end

  // ---- t + 1: the product as sum + carry ----
  logic [PW-1:0] sum_d, car_d, sum_q, car_q;
  if (!STRUCT) begin : g_beh
    logic signed [PW-1:0] prod;
    always_comb begin
      prod  = $signed(a_q) * $signed(b_q);           // signed x signed, extended to 2*XLEN bits by context
      sum_d = prod;
      car_d = '0;
    end
  end else begin : g_tree
    // Modified Radix-4 Booth encoding over AW-bit signed multiplier b_q (sign-extended + 0 at LSB).
    // Each of the NB groups selects d_j in {-2,-1,0,+1,+2} * a_q as an MW-bit signed partial product pp
    // (inverted when neg=1, with +1 collected into s_vec at bit 2*j). Sign extension mod 2^PW uses:
    //   sext(pp) === {~pp[MW-1], pp} - 2^MW  (mod 2^PW)
    // All -2^(MW+2*j) terms fold into CONST_FIX (bits MW..PW-1), disjoint from s_vec (bits 0..2*(NB-1)).
    logic [PW-1:0] rows [NL+1][NC];
    always_comb begin
      logic [AW+1:0] b_pad;
      logic [MW-1:0] a1, a2, mag, pp;
      logic [PW-1:0] s_vec;
      logic [2:0]    win;
      logic          neg;
      int n;
      for (int l = 0; l <= NL; l++) for (int r = 0; r < NC; r++) rows[l][r] = '0;
      b_pad = {b_q[AW-1], b_q, 1'b0};
      a1    = {{(MW - AW){a_q[AW-1]}}, a_q};
      a2    = {{(MW - AW - 1){a_q[AW-1]}}, a_q, 1'b0};
      s_vec = '0;
      for (int j = 0; j < NB; j++) begin
        win = b_pad[2*j +: 3];
        unique case (win)
          3'b000, 3'b111: begin neg = 1'b0; mag = '0; end
          3'b001, 3'b010: begin neg = 1'b0; mag = a1; end
          3'b011:         begin neg = 1'b0; mag = a2; end
          3'b100:         begin neg = 1'b1; mag = a2; end
          3'b101, 3'b110: begin neg = 1'b1; mag = a1; end
        endcase
        pp = neg ? ~mag : mag;
        rows[0][j] = PW'({~pp[MW-1], pp}) << (2 * j);
        s_vec[2*j] = neg;
      end
      rows[0][NB] = CONST_FIX | s_vec;
      n = NC;
      for (int l = 0; l < NL; l++) begin             // one level of 3:2 compressors over the groups of three rows
        for (int g = 0; g < n / 3; g++) begin
          rows[l+1][2*g]   = rows[l][3*g] ^ rows[l][3*g+1] ^ rows[l][3*g+2];
          rows[l+1][2*g+1] = ((rows[l][3*g] & rows[l][3*g+1]) |
                              (rows[l][3*g] & rows[l][3*g+2]) |
                              (rows[l][3*g+1] & rows[l][3*g+2])) << 1;
        end
        for (int k = 0; k < n % 3; k++) rows[l+1][2 * (n / 3) + k] = rows[l][3 * (n / 3) + k];
        n = rows_next(n);
      end
    end
    assign sum_d = rows[NL][0];
    assign car_d = rows[NL][1];
  end

  always_ff @(posedge clk) begin
    sum_q <= sum_d;
    car_q <= car_d;
    f3_s2_q  <= f3_q;
    wd_s2_q  <= wd_q;
  end

  // ---- t + 2: carry-propagate add and half select ----
  logic [PW-1:0] prod_w;
  if (!STRUCT) begin : g_add
    assign prod_w = sum_q + car_q;
  end else begin : g_ks
    // Kogge-Stone parallel-prefix adder (log2(PW) levels; the `+` of a synthesis tool maps to a long carry chain)
    localparam int LV = $clog2(PW);
    logic [PW-1:0] gg [LV+1];
    logic [PW-1:0] pp [LV+1];
    always_comb begin
      gg[0] = sum_q & car_q;
      pp[0] = sum_q ^ car_q;
      for (int l = 0; l < LV; l++) begin
        for (int i = 0; i < PW; i++) begin
          if (i >= (1 << l)) begin
            gg[l+1][i] = gg[l][i] | (pp[l][i] & gg[l][i - (1 << l)]);
            pp[l+1][i] = pp[l][i] & pp[l][i - (1 << l)];
          end else begin
            gg[l+1][i] = gg[l][i];
            pp[l+1][i] = pp[l][i];
          end
        end
      end
    end
    assign prod_w = pp[0] ^ {gg[LV][PW-2:0], 1'b0};
  end

  always_comb begin
    if (wd_s2_q)                result = {{(W - HW){prod_w[HW-1]}}, prod_w[HW-1:0]};
    else if (f3_s2_q == 2'd0)   result = prod_w[W-1:0];
    else                     result = prod_w[PW-1:W];
  end

endmodule

`default_nettype wire
