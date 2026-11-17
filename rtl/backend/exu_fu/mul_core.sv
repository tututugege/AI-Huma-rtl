// Ref: back-end/Exu/include/Fu.h  MulUnit::impl_compute (mul / mulh / mulhsu / mulhu, and rv64 mulw)
`default_nettype none

// XLENxXLEN multiplier spread over the latency of the unit (MUL_MAX_LATENCY = 3 cycles from the accept cycle to the result):
//   accept cycle t : operands (sign / zero extended by func3) -> registers a_q, b_q
//   t + 1          : the 2*XLEN-bit product of the registered operands, as two vectors (carry-save: sum_q + car_q)
//   t + 2 (result) : the carry-propagate add and the select of the half (mul / mulh* / mulw), combinational to the output
// The result is valid in cycle t + 2 only: the unit's result pipeline (mul_pipe) completes the entry exactly then, and the
// write-back reservation of the ISU guarantees that it is consumed in that cycle (checked in simulation by mul_unit).
//   func3[1:0]: 0 mul (low half) 1 mulh (signed x signed) 2 mulhsu (signed x unsigned) 3 mulhu (unsigned x unsigned).
//   rv64 mulw (is_word, func3 = 0): the low word of the product, sign-extended.
// STRUCT = 0: the product is `a * b` (simple, fast to simulate); STRUCT = 1: an explicit Wallace tree (AND array, 3:2 compressors).
// Default: the structural one for synthesis (SYNTHESIS defined), the behavioural one for simulation. scripts/mul_check.sh compares them.
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
  localparam int NR = AW + 2;              // rows of the tree: AW partial products and the two sign corrections

  function automatic int rows_next(input int n);
    return 2 * (n / 3) + (n % 3);
  endfunction
  function automatic int num_levels();
    int n = NR + 1, l = 0;                         // + the constant row
    for (int i = 0; i < NR; i++) if (n > 2) begin n = rows_next(n); l++; end
    return l;
  endfunction
  localparam int NL = num_levels();
  localparam int NC = NR + 1;

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
    // The operands are two's complement of AW bits: a = Au - 2^AW * as (Au the unsigned reading, as the sign bit), the same for b. Modulo
    // 2^PW the product is Au*Bu - 2^AW * (as*Bu + bs*Au) (the 2^2AW*as*bs term is gone): AW rows of the unsigned AND array, plus the two
    // corrections, subtracted as ~(x << AW) + 1 over PW bits (the two +1 are the constant row).
    logic [PW-1:0] rows [NL+1][NC];
    always_comb begin
      int n;
      for (int l = 0; l <= NL; l++) for (int r = 0; r < NC; r++) rows[l][r] = '0;
      for (int i = 0; i < AW; i++) rows[0][i] = (PW'(a_q) & {PW{b_q[i]}}) << i;
      rows[0][AW]     = ~((PW'(b_q) & {PW{a_q[AW-1]}}) << AW);
      rows[0][AW + 1] = ~((PW'(a_q) & {PW{b_q[AW-1]}}) << AW);
      rows[0][AW + 2] = PW'(2);
      n = NC;
      for (int l = 0; l < NL; l++) begin             // one level of 3:2 compressors over the groups of three rows
        for (int g = 0; g < n / 3; g++) begin
          rows[l+1][2*g]   = rows[l][3*g] ^ rows[l][3*g+1] ^ rows[l][3*g+2];
          rows[l+1][2*g+1] = ((rows[l][3*g] & rows[l][3*g+1]) | (rows[l][3*g] & rows[l][3*g+2]) | (rows[l][3*g+1] & rows[l][3*g+2])) << 1;
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
