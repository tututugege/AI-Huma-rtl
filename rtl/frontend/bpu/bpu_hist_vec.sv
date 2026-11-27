// Ref: front-end/BPU/BPU_pipe.h  HistRing::push (Clean BPU v11: HR_BITS=256, unified ex_fh[3][6] only)
`default_nettype none

module bpu_hist_vec import bpu_pkg::*; import bpu_stage_pkg::*; #(
  parameter int MAX_SYM = 2,
  parameter int DW      = 24
) (
  input  hist_t          h,
  input  logic [3:0]     sym_n,
  input  logic [DW-1:0]  d,
  output hist_t          h_next
);

  localparam int NW = 3 * MAX_SYM;

`ifdef SYNTHESIS
  function automatic logic [EX_FH_W-1:0] rotl_const_ex(input logic [EX_FH_W-1:0] x, input int unsigned a,
                                                       input int unsigned len);
    logic [EX_FH_W-1:0] msk;
    msk = EX_FH_W'((32'd1 << len) - 32'd1);
    return (a == 0) ? x : (((x << a) | (x >> (len - a))) & msk);
  endfunction

  function automatic logic [EX_FH_W-1:0] rotl_sym_ex(input logic [EX_FH_W-1:0] x, input logic [3:0] sn,
                                                     input int unsigned len);
    case (sn)
      4'd1:    return rotl_const_ex(x,  3 % len, len);
      4'd2:    return rotl_const_ex(x,  6 % len, len);
      4'd3:    return rotl_const_ex(x,  9 % len, len);
      4'd4:    return rotl_const_ex(x, 12 % len, len);
      4'd5:    return rotl_const_ex(x, 15 % len, len);
      4'd6:    return rotl_const_ex(x, 18 % len, len);
      4'd7:    return rotl_const_ex(x, 21 % len, len);
      4'd8:    return rotl_const_ex(x, 24 % len, len);
      default: return x;
    endcase
  endfunction

  logic [5:0]          n_bits;
  logic [HR_PTR_W-1:0] head_new;
  logic [NW-1:0]       keep, din, din_of;
  logic [HR_BITS-1:0]  ring_new;
  logic [NW-1:0]       ex_outw [EX_TN];

  assign n_bits   = {2'b0, sym_n} + {1'b0, sym_n, 1'b0}; // 3 * sym_n
  assign head_new = h.head + HR_PTR_W'(n_bits);

  always_comb begin
    for (int u = 0; u < NW; u++) begin
      keep[u] = (6'(u) < n_bits);
      din[u]  = d[u] && keep[u];
    end
    din_of = '0;
    for (int c = 1; c <= MAX_SYM; c++) begin
      if (sym_n == 4'(c)) begin
        for (int j = 0; j < 3 * c; j++) din_of[j] = d[3 * c - 1 - j];
      end
    end
  end

  always_comb begin
    logic [HR_BITS + NW - 2 : 0] e_sh, m_sh;
    logic [HR_BITS-1:0]          ring_e, ring_m;
    e_sh   = {{(HR_BITS - 1){1'b0}}, din_of} << h.head;
    m_sh   = {{(HR_BITS - 1){1'b0}}, keep}   << h.head;
    ring_e = e_sh[HR_BITS-1:0] | {{(HR_BITS - NW + 1){1'b0}}, e_sh[HR_BITS + NW - 2 : HR_BITS]};
    ring_m = m_sh[HR_BITS-1:0] | {{(HR_BITS - NW + 1){1'b0}}, m_sh[HR_BITS + NW - 2 : HR_BITS]};
    ring_new = (h.ring & ~ring_m) | ring_e;
  end

  logic [HR_BITS + NW - 2 : 0] ring_ext;
  assign ring_ext = {h.ring[NW-2:0], h.ring};

  always_comb begin
    for (int i = 0; i < EX_TN; i++) begin
      logic [HR_PTR_W-1:0] rbase;
      logic [NW-1:0]       raw_o;
      rbase = h.head - HR_PTR_W'(ex_ghr_len(i));
      raw_o = ring_ext[{1'b0, rbase} +: NW];
      for (int j = 0; j < NW; j++) begin
        if (j >= ex_ghr_len(i)) raw_o[j] = din_of[j - ex_ghr_len(i)];
      end
      ex_outw[i] = '0;
      for (int c = 1; c <= MAX_SYM; c++) begin
        if (sym_n == 4'(c)) begin
          for (int u = 0; u < 3 * c; u++) ex_outw[i][u] = raw_o[3 * c - 1 - u];
        end
      end
    end
  end

  always_comb begin
    h_next      = h;
    h_next.ring = ring_new;
    h_next.head = head_new;
    for (int k = 0; k < EX_FH_K; k++) begin
      for (int i = 0; i < EX_TN; i++) begin
        logic [EX_FH_W-1:0] acc;
        acc = rotl_sym_ex(h.ex_fh[k][i], sym_n, ex_fh_len(k));
        for (int u = 0; u < NW; u++) begin
          acc = acc ^ rotl_const_ex(EX_FH_W'(din[u]) ^ (EX_FH_W'(ex_outw[i][u]) << (ex_ghr_len(i) % ex_fh_len(k))),
                                    u % ex_fh_len(k), ex_fh_len(k));
        end
        h_next.ex_fh[k][i] = acc;
      end
    end
  end
`else
  // Fast simulation path (bit-identical to parallel synthesis path above)
  always_comb begin
    localparam int BIDXW = $clog2(DW);
    logic [5:0]         nb;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0]         bidx;
    /* verilator lint_on UNUSEDSIGNAL */
    logic               b, ob;
    int unsigned        fl, gl;
    logic [EX_FH_W-1:0] emsk, ev;
    h_next = h;
    nb     = {2'b0, sym_n} + {1'b0, sym_n, 1'b0};
    bidx   = '0;
    b      = 1'b0;
    ob     = 1'b0;
    fl     = 0;
    gl     = 0;
    emsk   = '0;
    ev     = '0;
    for (int j = 0; j < NW; j++) begin
      if (6'(j) < nb) begin
        bidx = nb - 6'd1 - 6'(j);
        b    = d[bidx[BIDXW-1:0]];
        h_next.ring[h_next.head] = b;
        h_next.head = h_next.head + HR_PTR_W'(1);
        for (int k = 0; k < EX_FH_K; k++) begin
          fl   = ex_fh_len(k);
          emsk = EX_FH_W'((32'd1 << fl) - 32'd1);
          for (int i = 0; i < EX_TN; i++) begin
            gl = ex_ghr_len(i);
            ob = h_next.ring[h_next.head - HR_PTR_W'(gl + 1)];
            ev = ((h_next.ex_fh[k][i] << 1) | (h_next.ex_fh[k][i] >> (fl - 1))) & emsk;
            ev = ev ^ EX_FH_W'(b);
            ev = ev ^ (EX_FH_W'(ob) << (gl % fl));
            h_next.ex_fh[k][i] = ev & emsk;
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
