// Ref: back-end/Exu/include/Fu.h  div_radix16_latency (1x Radix-16 / dual Radix-4 early-out divider)
`default_nettype none

// Variable-latency Radix-16 (dual Radix-4, 4 quotient bits/cycle) early-out divider for RV64 div/divu/rem/remu/*W.
//   accept cycle : compute |a|, |b|, early-out check (b==0 || |a|<|b|), clz64 diff -> lat_m1 (1..16),
//                  4-bit-step barrel left-shift of |a| by (60 - (diff & ~3)), and precompute 3*|b|.
//   run cycles   : 1..16 cycles of 2 cascaded Radix-4 steps (4 bits/cycle); held unchanged when early-out.
//   complete     : sign fix-up of quotient or remainder (single shared Kogge-Stone negator).
// Total latency = lat_m1 + 1 = 2..17 cycles (2 for early-out or 1..4 quotient bits, up to 17 for 61..64 bits).
//   STRUCT = 0 (default in simulation): behavioural 4-step restoring loop, fast to simulate.
//   STRUCT = 1 (default in synthesis) : dual parallel Radix-4 with 66-bit Kogge-Stone subtractors.
module div_core
  import ttg_cfg_pkg::*;
  import fp_arith_pkg::clz64;
#(
  /* verilator lint_off UNUSEDPARAM */
  parameter int LAT = DIV_MAX_LATENCY,
  /* verilator lint_on UNUSEDPARAM */
`ifdef SYNTHESIS
  parameter bit STRUCT = 1'b1
`else
  parameter bit STRUCT = 1'b0
`endif
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 accept,
  input  logic                 run,
  input  logic [1:0]           func3,        // 0 div, 1 divu, 2 rem, 3 remu
  input  logic                 is_word,
  input  logic [XLEN_BITS-1:0] src1_rdata,
  input  logic [XLEN_BITS-1:0] src2_rdata,
  output logic [4:0]           lat_m1,       // cycles to wait after accept (1..16 -> total latency 2..17)
  output logic [XLEN_BITS-1:0] result        // valid when complete
);

  localparam int W  = XLEN_BITS;
  localparam int HW = XLEN_BITS / 2;
  localparam int SW = W + 2;                 // 66 bits for shifted remainder & 1d/2d/3d

  // ---- state ----
  logic [W-1:0] rem_q, rem_d, qd_q, qd_d, dvs_q, dvs_d;
  logic         eo_q, eo_d, is_rem_q, is_rem_d, neg_q_q, neg_q_d, neg_r_q, neg_r_d, word_q, word_d;

  if (!STRUCT) begin : g_beh
    // ---- accept side: magnitudes, early-out, clz64 alignment ----
    logic          is_signed, a_neg, b_neg, b_nz, early_out;
    logic [HW-1:0] a_mag_w, b_mag_w;
    logic [W-1:0]  a_mag, b_mag, a_shifted, a_rem0;
    logic [6:0]    lz_a, lz_b;
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0]    diff;
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on UNUSEDSIGNAL */
    logic [5:0]    sh_amt;
    logic [4:0]    iters;

    always_comb begin
      is_signed = !func3[0];
      a_neg     = is_signed && (is_word ? src1_rdata[HW-1] : src1_rdata[W-1]);
      b_neg     = is_signed && (is_word ? src2_rdata[HW-1] : src2_rdata[W-1]);
      a_mag_w   = a_neg ? (HW'(0) - src1_rdata[HW-1:0]) : src1_rdata[HW-1:0];
      b_mag_w   = b_neg ? (HW'(0) - src2_rdata[HW-1:0]) : src2_rdata[HW-1:0];
      a_mag     = is_word ? {{HW{1'b0}}, a_mag_w} : (a_neg ? ('0 - src1_rdata) : src1_rdata);
      b_mag     = is_word ? {{HW{1'b0}}, b_mag_w} : (b_neg ? ('0 - src2_rdata) : src2_rdata);
      b_nz      = (b_mag != '0);
      early_out = (!b_nz) || (a_mag < b_mag);

      lz_a      = clz64(a_mag);
      lz_b      = clz64(b_mag);
      diff      = 6'(lz_b - lz_a);
      iters     = {1'b0, diff[5:2]} + 5'd1;              // 1..16
      sh_amt    = 6'd60 - {diff[5:2], 2'b00};            // 0..60 in steps of 4
      a_shifted = a_mag << sh_amt;
      a_rem0    = (iters == 5'd16) ? '0 : (a_mag >> {iters[3:0], 2'b00});
      lat_m1    = early_out ? 5'd1 : iters;
    end

    // ---- run side: 4 restoring steps per cycle ----
    logic [W-1:0] rem_s [5];
    logic [W-1:0] qd_s  [5];
    always_comb begin
      rem_s[0] = rem_q;
      qd_s[0]  = qd_q;
    end
    for (genvar s = 0; s < 4; s++) begin : g_step
      div_step u_step (
        .rem_in(rem_s[s]), .qd_in(qd_s[s]), .divisor(dvs_q), .rem_out(rem_s[s+1]), .qd_out(qd_s[s+1])
      );
    end

    always_comb begin
      if (accept) begin
        rem_d    = early_out ? a_mag : a_rem0;
        qd_d     = early_out ? (b_nz ? '0 : {W{1'b1}}) : a_shifted;
        dvs_d    = b_mag;
        eo_d     = early_out;
        is_rem_d = func3[1];
        neg_q_d  = (a_neg != b_neg) && b_nz;
        neg_r_d  = a_neg;
        word_d   = is_word;
      end else if (run && !eo_q) begin
        rem_d    = rem_s[4];
        qd_d     = qd_s[4];
        dvs_d    = dvs_q;
        eo_d     = eo_q;
        is_rem_d = is_rem_q;
        neg_q_d  = neg_q_q;
        neg_r_d  = neg_r_q;
        word_d   = word_q;
      end else begin
        rem_d    = rem_q;
        qd_d     = qd_q;
        dvs_d    = dvs_q;
        eo_d     = eo_q;
        is_rem_d = is_rem_q;
        neg_q_d  = neg_q_q;
        neg_r_d  = neg_r_q;
        word_d   = word_q;
      end
    end

    logic [W-1:0]  quo, rmd;
    logic [HW-1:0] quo_w, rmd_w, res_w;
    always_comb begin
      quo_w  = neg_q_q ? (HW'(0) - qd_q[HW-1:0]) : qd_q[HW-1:0];
      rmd_w  = neg_r_q ? (HW'(0) - rem_q[HW-1:0]) : rem_q[HW-1:0];
      res_w  = is_rem_q ? rmd_w : quo_w;
      quo    = neg_q_q ? ('0 - qd_q) : qd_q;
      rmd    = neg_r_q ? ('0 - rem_q) : rem_q;
      result = word_q ? {{(W - HW){res_w[HW-1]}}, res_w} : (is_rem_q ? rmd : quo);
    end
  end else begin : g_struct
    function automatic logic [W-1:0] ks_neg_w(input logic [W-1:0] x);
      localparam int LV = $clog2(W);
      logic [W-1:0] g [LV+1];
      logic [W-1:0] p [LV+1];
      logic [W-1:0] inv;
      inv  = ~x;
      g[0] = {{(W-1){1'b0}}, inv[0]};
      p[0] = inv;
      for (int l = 0; l < LV; l++) begin
        for (int i = 0; i < W; i++) begin
          if (i >= (1 << l)) begin
            g[l+1][i] = g[l][i] | (p[l][i] & g[l][i - (1 << l)]);
            p[l+1][i] = p[l][i] & p[l][i - (1 << l)];
          end else begin
            g[l+1][i] = g[l][i];
            p[l+1][i] = p[l][i];
          end
        end
      end
      return inv ^ {g[LV][W-2:0], 1'b1};
    endfunction

    function automatic logic [SW:0] ks_add_sw(input logic [SW-1:0] a, input logic [SW-1:0] b, input logic cin);
      localparam int LV = $clog2(SW);
      logic [SW-1:0] g [LV+1];
      logic [SW-1:0] p [LV+1];
      logic [SW-1:0] sum;
      logic          cout;
      p[0] = a ^ b;
      g[0] = (a & b) | {{(SW-1){1'b0}}, (p[0][0] & cin)};
      for (int l = 0; l < LV; l++) begin
        for (int i = 0; i < SW; i++) begin
          if (i >= (1 << l)) begin
            g[l+1][i] = g[l][i] | (p[l][i] & g[l][i - (1 << l)]);
            p[l+1][i] = p[l][i] & p[l][i - (1 << l)];
          end else begin
            g[l+1][i] = g[l][i];
            p[l+1][i] = p[l][i];
          end
        end
      end
      sum  = p[0] ^ {g[LV][SW-2:0], cin};
      cout = g[LV][SW-1];
      return {cout, sum};
    endfunction

    // Extra state: precomputed 3 * dvs_q (66 bits)
    logic [SW-1:0] dvs3_q, dvs3_d;

    // ---- accept side: Kogge-Stone magnitudes, early-out, clz64, 4-bit-step shift, 3*b_mag ----
    logic          is_signed, a_neg, b_neg, b_nz, early_out;
    logic [W-1:0]  a_in_w, b_in_w, a_neg_v, b_neg_v, a_mag, b_mag, a_shifted, a_rem0;
    logic [6:0]    lz_a, lz_b;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0]    diff;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]    sh4;
    logic [4:0]    iters;
    logic [SW-1:0] b3_calc;
    logic [SW:0]   cmp_ab;

    always_comb begin
      is_signed = !func3[0];
      a_neg     = is_signed && (is_word ? src1_rdata[HW-1] : src1_rdata[W-1]);
      b_neg     = is_signed && (is_word ? src2_rdata[HW-1] : src2_rdata[W-1]);
      a_in_w    = is_word ? {{HW{1'b0}}, src1_rdata[HW-1:0]} : src1_rdata;
      b_in_w    = is_word ? {{HW{1'b0}}, src2_rdata[HW-1:0]} : src2_rdata;
      a_neg_v   = ks_neg_w(a_in_w);
      b_neg_v   = ks_neg_w(b_in_w);
      a_mag     = is_word ? {{HW{1'b0}}, (a_neg ? a_neg_v[HW-1:0] : src1_rdata[HW-1:0])}
                          : (a_neg ? a_neg_v : src1_rdata);
      b_mag     = is_word ? {{HW{1'b0}}, (b_neg ? b_neg_v[HW-1:0] : src2_rdata[HW-1:0])}
                          : (b_neg ? b_neg_v : src2_rdata);
      b_nz      = |b_in_w;

      // Fast Kogge-Stone compare a_mag >= b_mag
      cmp_ab    = ks_add_sw({2'b00, a_mag}, ~{2'b00, b_mag}, 1'b1);
      early_out = (!b_nz) || !cmp_ab[SW];

      lz_a      = clz64(a_mag);
      lz_b      = clz64(b_mag);
      diff      = 6'(lz_b - lz_a);
      iters     = {1'b0, diff[5:2]} + 5'd1;              // 1..16
      sh4       = 4'd15 - diff[5:2];                     // 0..15 nibbles (0..60 bits)
      a_shifted = a_mag << {sh4, 2'b00};
      a_rem0    = (iters == 5'd16) ? '0 : (a_mag >> {iters[3:0], 2'b00});
      lat_m1    = early_out ? 5'd1 : iters;

      begin
        logic [SW:0] b3_tmp;
        b3_tmp  = ks_add_sw({2'b00, b_mag}, {1'b0, b_mag, 1'b0}, 1'b0);
        b3_calc = b3_tmp[SW-1:0];
      end
    end

    // ---- run side: 2 cascaded parallel Radix-4 stages (4 quotient bits/cycle) ----
    logic [SW-1:0] d1, d2, sh2_a, sh2_b;
    logic [SW:0]   sub1_a, sub2_a, sub3_a, sub1_b, sub2_b, sub3_b;
    logic [W-1:0]  rem_mid, run_rem, run_qd;
    logic [1:0]    q_hi, q_lo;

    always_comb begin
      d1     = {2'b00, dvs_q};
      d2     = {1'b0,  dvs_q, 1'b0};

      // Stage A: upper 2 quotient bits
      sh2_a  = {rem_q, qd_q[W-1:W-2]};
      sub1_a = ks_add_sw(sh2_a, ~d1,     1'b1);
      sub2_a = ks_add_sw(sh2_a, ~d2,     1'b1);
      sub3_a = ks_add_sw(sh2_a, ~dvs3_q, 1'b1);
      if (sub3_a[SW])      begin q_hi = 2'd3; rem_mid = sub3_a[W-1:0]; end
      else if (sub2_a[SW]) begin q_hi = 2'd2; rem_mid = sub2_a[W-1:0]; end
      else if (sub1_a[SW]) begin q_hi = 2'd1; rem_mid = sub1_a[W-1:0]; end
      else                 begin q_hi = 2'd0; rem_mid = sh2_a[W-1:0];  end

      // Stage B: lower 2 quotient bits
      sh2_b  = {rem_mid, qd_q[W-3:W-4]};
      sub1_b = ks_add_sw(sh2_b, ~d1,     1'b1);
      sub2_b = ks_add_sw(sh2_b, ~d2,     1'b1);
      sub3_b = ks_add_sw(sh2_b, ~dvs3_q, 1'b1);
      if (sub3_b[SW])      begin q_lo = 2'd3; run_rem = sub3_b[W-1:0]; end
      else if (sub2_b[SW]) begin q_lo = 2'd2; run_rem = sub2_b[W-1:0]; end
      else if (sub1_b[SW]) begin q_lo = 2'd1; run_rem = sub1_b[W-1:0]; end
      else                 begin q_lo = 2'd0; run_rem = sh2_b[W-1:0];  end

      run_qd = {qd_q[W-5:0], q_hi, q_lo};
    end

    always_comb begin
      if (accept) begin
        rem_d    = early_out ? a_mag : a_rem0;
        qd_d     = early_out ? (b_nz ? '0 : {W{1'b1}}) : a_shifted;
        dvs_d    = b_mag;
        dvs3_d   = b3_calc;
        eo_d     = early_out;
        is_rem_d = func3[1];
        neg_q_d  = (a_neg != b_neg) && b_nz;
        neg_r_d  = a_neg;
        word_d   = is_word;
      end else if (run && !eo_q) begin
        rem_d    = run_rem;
        qd_d     = run_qd;
        dvs_d    = dvs_q;
        dvs3_d   = dvs3_q;
        eo_d     = eo_q;
        is_rem_d = is_rem_q;
        neg_q_d  = neg_q_q;
        neg_r_d  = neg_r_q;
        word_d   = word_q;
      end else begin
        rem_d    = rem_q;
        qd_d     = qd_q;
        dvs_d    = dvs_q;
        dvs3_d   = dvs3_q;
        eo_d     = eo_q;
        is_rem_d = is_rem_q;
        neg_q_d  = neg_q_q;
        neg_r_d  = neg_r_q;
        word_d   = word_q;
      end
    end

    // ---- result: single shared Kogge-Stone negator ----
    logic [W-1:0] raw_res, neg_res, fin_res;
    logic         do_neg;
    always_comb begin
      raw_res = is_rem_q ? rem_q : qd_q;
      do_neg  = is_rem_q ? neg_r_q : neg_q_q;
      neg_res = ks_neg_w(raw_res);
      fin_res = do_neg ? neg_res : raw_res;
      result  = word_q ? {{(W - HW){fin_res[HW-1]}}, fin_res[HW-1:0]} : fin_res;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) dvs3_q <= '0;
      else        dvs3_q <= dvs3_d;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rem_q    <= '0;
      qd_q     <= '0;
      dvs_q    <= '0;
      eo_q     <= 1'b0;
      is_rem_q <= 1'b0;
      neg_q_q  <= 1'b0;
      neg_r_q  <= 1'b0;
      word_q   <= 1'b0;
    end else begin
      rem_q    <= rem_d;
      qd_q     <= qd_d;
      dvs_q    <= dvs_d;
      eo_q     <= eo_d;
      is_rem_q <= is_rem_d;
      neg_q_q  <= neg_q_d;
      neg_r_q  <= neg_r_d;
      word_q   <= word_d;
    end
  end

endmodule

`default_nettype wire
