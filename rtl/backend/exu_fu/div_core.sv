// Ref: back-end/Exu/include/Fu.h  DivUnit::impl_compute
`default_nettype none

// Iterative 32-bit divider for div / divu / rem / remu.  Latency LAT cycles from accept to complete, with
// 32 / LAT restoring steps per cycle (2 per cycle at LAT = 16).  Signed operations divide the magnitudes and fix the
// signs at the end: quotient negated if the operand signs differ (not for a zero divisor), remainder takes the
// dividend's sign.  Zero divisor: quotient -1 / all ones, remainder = dividend.  INT_MIN / -1: quotient INT_MIN,
// remainder 0 (falls out of the magnitude arithmetic).
// accept: step the freshly loaded operands once (this is the first of the LAT iterations) and load the state.
// run   : one iteration per cycle while the control says the uop is in flight and not finished.
module div_core #(
  parameter int LAT = 16
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        accept,
  input  logic        run,
  input  logic [1:0]  func3,          // 0 div, 1 divu, 2 rem, 3 remu
  input  logic [31:0] src1_rdata,
  input  logic [31:0] src2_rdata,
  output logic [31:0] result          // valid when the control reports complete
);

  localparam int STEPS = 32 / LAT;    // restoring steps per cycle

`ifndef SYNTHESIS
  if (LAT * STEPS != 32) begin : g_lat_check
    $error("div_core: LAT must divide 32");
  end
`endif

  // ---- state ----
  logic [31:0] rem_q, rem_d, qd_q, qd_d, dvs_q, dvs_d;
  logic        is_rem_q, is_rem_d, neg_q_q, neg_q_d, neg_r_q, neg_r_d;

  // ---- accept side: magnitudes and sign flags ----
  logic        is_signed, a_neg, b_neg;
  logic [31:0] a_mag, b_mag;
  always_comb begin
    is_signed = !func3[0];
    a_neg     = is_signed && src1_rdata[31];
    b_neg     = is_signed && src2_rdata[31];
    a_mag     = a_neg ? (32'd0 - src1_rdata) : src1_rdata;
    b_mag     = b_neg ? (32'd0 - src2_rdata) : src2_rdata;
  end

  // ---- iteration chain: STEPS steps from the (loaded or running) state ----
  logic [31:0] rem_in, qd_in, dvs_in;
  logic [31:0] rem_s [STEPS+1];
  logic [31:0] qd_s  [STEPS+1];

  always_comb begin
    rem_in = accept ? 32'd0 : rem_q;
    qd_in  = accept ? a_mag : qd_q;
    dvs_in = accept ? b_mag : dvs_q;
    rem_s[0] = rem_in;
    qd_s[0]  = qd_in;
  end

  for (genvar s = 0; s < STEPS; s++) begin : g_step
    div_step u_step (
      .rem_in(rem_s[s]), .qd_in(qd_s[s]), .divisor(dvs_in), .rem_out(rem_s[s+1]), .qd_out(qd_s[s+1])
    );
  end

  // ---- next state: load on accept, advance on run, otherwise hold ----
  always_comb begin
    rem_d    = (accept || run) ? rem_s[STEPS] : rem_q;
    qd_d     = (accept || run) ? qd_s[STEPS] : qd_q;
    dvs_d    = accept ? b_mag : dvs_q;
    is_rem_d = accept ? func3[1] : is_rem_q;
    neg_q_d  = accept ? ((a_neg != b_neg) && (src2_rdata != 32'd0)) : neg_q_q;
    neg_r_d  = accept ? a_neg : neg_r_q;
  end

  // ---- result (sign fix-up of the registered magnitudes) ----
  logic [31:0] quo, rmd;
  always_comb begin
    quo    = neg_q_q ? (32'd0 - qd_q) : qd_q;
    rmd    = neg_r_q ? (32'd0 - rem_q) : rem_q;
    result = is_rem_q ? rmd : quo;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rem_q    <= '0;
      qd_q     <= '0;
      dvs_q    <= '0;
      is_rem_q <= 1'b0;
      neg_q_q  <= 1'b0;
      neg_r_q  <= 1'b0;
    end else begin
      rem_q    <= rem_d;
      qd_q     <= qd_d;
      dvs_q    <= dvs_d;
      is_rem_q <= is_rem_d;
      neg_q_q  <= neg_q_d;
      neg_r_q  <= neg_r_d;
    end
  end

endmodule

`default_nettype wire
