// Ref: front-end/BPU/BPU_pipe.h  HistRing::push (parallel n-symbol push, zero variable modulo)
`default_nettype none

// Pushes sym_n (0..MAX_SYM) 3-bit history symbols (n = 3*sym_n bits) into the ring and 12 folded histories.
//   d[u] is the bit pushed u pushes before the last one (d[0] = newest); d[u] = 0 for u >= 3*sym_n.
//   - Outgoing window bit raw_o[j] (for 0 <= j < n_bits) is ring_new[head - ghr_len(i) + j]:
//     * for j < ghr_len(i), it comes directly from h.ring[head - ghr_len(i) + j] (independent of ring_new!);
//     * for j >= ghr_len(i), it comes directly from din_of[j - ghr_len(i)] (also independent of ring_new!).
//     Thus ring_new and all 12 folded histories compute completely in parallel for both spec (MAX_SYM=4) and arch (MAX_SYM=8).
//   - Folded-history rotation uses compile-time constant case over sym_n (zero hardware divider/modulo).
module bpu_hist_vec import bpu_pkg::*; import bpu_stage_pkg::*; #(
  parameter int MAX_SYM = 8,
  parameter int DW      = 24
) (
  input  hist_t          h,
  input  logic [3:0]     sym_n,
  input  logic [DW-1:0]  d,
  output hist_t          h_next
);

  localparam int NW = 3 * MAX_SYM;

`ifdef SYNTHESIS
  function automatic logic [FH_W-1:0] rotl_const(input logic [FH_W-1:0] x, input int unsigned a, input int unsigned len);
    logic [FH_W-1:0] msk;
    msk = FH_W'((32'd1 << len) - 32'd1);
    return a == 0 ? x : (((x << a) | (x >> (len - a))) & msk);
  endfunction

  function automatic logic [FH_W-1:0] rotl_sym(input logic [FH_W-1:0] x, input logic [3:0] sn, input int unsigned len);
    case (sn)
      4'd1:    return rotl_const(x,  3 % len, len);
      4'd2:    return rotl_const(x,  6 % len, len);
      4'd3:    return rotl_const(x,  9 % len, len);
      4'd4:    return rotl_const(x, 12 % len, len);
      4'd5:    return rotl_const(x, 15 % len, len);
      4'd6:    return rotl_const(x, 18 % len, len);
      4'd7:    return rotl_const(x, 21 % len, len);
      4'd8:    return rotl_const(x, 24 % len, len);
      4'd9:    return rotl_const(x, 27 % len, len);
      4'd10:   return rotl_const(x, 30 % len, len);
      4'd11:   return rotl_const(x, 33 % len, len);
      4'd12:   return rotl_const(x, 36 % len, len);
      default: return x;
    endcase
  endfunction

  logic [5:0]          n_bits;
  logic [HR_PTR_W-1:0] head_new;
  logic [NW-1:0]       keep, din, din_of;
  logic [HR_BITS-1:0]  ring_new;
  logic [NW-1:0]       outw [TN];

  assign n_bits   = {2'b0, sym_n} + {1'b0, sym_n, 1'b0}; // 3 * sym_n (0..36)
  assign head_new = h.head + HR_PTR_W'(n_bits);

  always_comb begin
    for (int u = 0; u < NW; u++) begin
      keep[u] = (6'(u) < n_bits);
      din[u]  = d[u] && keep[u];
    end
    // Oldest-first bit order: din_of[j] is written to ring[(h.head + j) & (HR_BITS-1)] for j < n_bits
    din_of = '0;
    for (int c = 1; c <= MAX_SYM; c++) begin
      if (sym_n == 4'(c)) begin
        for (int j = 0; j < 3 * c; j++) din_of[j] = d[3 * c - 1 - j];
      end
    end
  end

  // Single left-shift circular ring update (zero subtraction / right-shift barrel shifter)
  always_comb begin
    logic [HR_BITS + NW - 2 : 0] e_sh, m_sh;
    logic [HR_BITS-1:0]          ring_e, ring_m;
    e_sh   = {{(HR_BITS - 1){1'b0}}, din_of} << h.head;
    m_sh   = {{(HR_BITS - 1){1'b0}}, keep}   << h.head;
    ring_e = e_sh[HR_BITS-1:0] | {{(HR_BITS - NW + 1){1'b0}}, e_sh[HR_BITS + NW - 2 : HR_BITS]};
    ring_m = m_sh[HR_BITS-1:0] | {{(HR_BITS - NW + 1){1'b0}}, m_sh[HR_BITS + NW - 2 : HR_BITS]};
    ring_new = (h.ring & ~ring_m) | ring_e;
  end

  // Outgoing window bits computed completely in parallel with ring_new:
  //   j < ghr_len(i) -> h.ring[(h.head - ghr_len(i) + j) mod HR_BITS]
  //   j >= ghr_len(i) -> din_of[j - ghr_len(i)] (bit written earlier in the same multi-symbol push)
  logic [HR_BITS + NW - 2 : 0] ring_ext;
  assign ring_ext = {h.ring[NW-2:0], h.ring};

  always_comb begin
    for (int i = 0; i < TN; i++) begin
      logic [HR_PTR_W-1:0] rbase;
      logic [NW-1:0]       raw_o;
      rbase = h.head - HR_PTR_W'(ghr_len(i));
      raw_o = ring_ext[{1'b0, rbase} +: NW];
      for (int j = 0; j < NW; j++) begin
        if (j >= ghr_len(i)) raw_o[j] = din_of[j - ghr_len(i)];
      end
      outw[i] = '0;
      for (int c = 1; c <= MAX_SYM; c++) begin
        if (sym_n == 4'(c)) begin
          for (int u = 0; u < 3 * c; u++) outw[i][u] = raw_o[3 * c - 1 - u];
        end
      end
    end
  end

  // Folded histories: compile-time constant rotations + parallel XOR tree
  always_comb begin
    h_next      = h;
    h_next.ring = ring_new;
    h_next.head = head_new;
    for (int k = 0; k < FH_K; k++) begin
      for (int i = 0; i < TN; i++) begin
        logic [FH_W-1:0] acc;
        acc = rotl_sym(h.fh[k][i], sym_n, fh_len(k, i));
        for (int u = 0; u < NW; u++) begin
          acc = acc ^ rotl_const(FH_W'(din[u]) ^ (FH_W'(outw[i][u]) << (ghr_len(i) % fh_len(k, i))),
                                 u % fh_len(k, i), fh_len(k, i));
        end
        h_next.fh[k][i] = acc;
      end
    end
  end
`else
  // Fast simulation path (bit-identical to parallel synthesis path above, verified by tb/fe_clean_eq)
  always_comb begin
    localparam int BIDXW = $clog2(DW);
    logic [5:0]      nb;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0]      bidx;
    /* verilator lint_on UNUSEDSIGNAL */
    logic            b, ob;
    int unsigned     fl, gl;
    logic [FH_W-1:0] msk, v;
    h_next = h;
    nb     = {2'b0, sym_n} + {1'b0, sym_n, 1'b0};
    bidx   = '0;
    b      = 1'b0;
    ob     = 1'b0;
    fl     = 0;
    gl     = 0;
    msk    = '0;
    v      = '0;
    for (int j = 0; j < NW; j++) begin
      if (6'(j) < nb) begin
        bidx = nb - 6'd1 - 6'(j);
        b    = d[bidx[BIDXW-1:0]];
        h_next.ring[h_next.head] = b;
        h_next.head = h_next.head + HR_PTR_W'(1);
        for (int k = 0; k < FH_K; k++) begin
          for (int i = 0; i < TN; i++) begin
            fl  = fh_len(k, i);
            gl  = ghr_len(i);
            msk = FH_W'((32'd1 << fl) - 32'd1);
            ob  = h_next.ring[h_next.head - HR_PTR_W'(gl + 1)];
            v   = ((h_next.fh[k][i] << 1) | (h_next.fh[k][i] >> (fl - 1))) & msk;
            v   = v ^ FH_W'(b);
            v   = v ^ (FH_W'(ob) << (gl % fl));
            h_next.fh[k][i] = v & msk;
          end
        end
      end
    end
  end
`endif

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_d;
  assign unused_d = ^d;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
