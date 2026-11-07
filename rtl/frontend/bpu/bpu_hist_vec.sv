// Ref: front-end/BPU/BPU_pipe.h  HistRing::push (n pushes at once)
`default_nettype none

// Pushes n (0..24) history bits into the ring and the 12 folded histories in ONE step instead of n chained
// single pushes.
//   d[u] is the bit pushed u pushes before the last one (d[0] = newest); d[u] = 0 for u >= n.
// A folded history of length L obeys v' = rotl(v, 1) ^ in ^ (out << r) (r = history length mod L, out = the bit that
// leaves the window), so n pushes are  rotl(v, n) ^ XOR_u rotl(in_u ^ (out_u << r), u): static rotations of the
// new bits and of the bits that leave the window, which are read from the updated ring at fixed distances from the
// new head.
module bpu_hist_vec import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  hist_t        h,
  input  logic [4:0]   n,
  input  logic [23:0]  d,
  output hist_t        h_next
);

  localparam int NW = 24;

  logic [HR_PTR_W-1:0] head_new;
  logic [NW-1:0]       keep;          // u < n
  logic [NW-1:0]       din;           // d masked
  logic [NW-1:0]       din_rev;       // bit k = d[23 - k]
  logic [NW-1:0]       keep_rev;
  logic [HR_BITS-1:0]  ring_new;
  logic [NW-1:0]       outw [TN];     // outgoing bits of every table, outw[i][u]

  // Ref: HistRing::push, ring write and window bits
  always_comb begin
    head_new = h.head + HR_PTR_W'(n);
    for (int u = 0; u < NW; u++) begin
      keep[u]       = (5'(u) < n);
      din[u]        = d[u] && keep[u];
      din_rev[NW - 1 - u]  = din[u];
      keep_rev[NW - 1 - u] = keep[u];
    end
    begin
      logic [HR_BITS-1:0] e, m;
      logic [HR_PTR_W-1:0] sh;
      sh = head_new - HR_PTR_W'(NW);
      e  = HR_BITS'(din_rev);
      m  = HR_BITS'(keep_rev);
      ring_new = (h.ring & ~((m << sh) | (m >> (HR_BITS - int'(sh))))) | ((e << sh) | (e >> (HR_BITS - int'(sh))));
    end
    for (int i = 0; i < TN; i++) begin
      logic [HR_BITS-1:0] win;
      logic [HR_PTR_W-1:0] base;
      base = head_new - HR_PTR_W'(ghr_len(i)) - HR_PTR_W'(NW);     // ring_new[base + k] = out[23 - k]
      win  = (ring_new >> base) | (ring_new << (HR_BITS - int'(base)));
      for (int u = 0; u < NW; u++) outw[i][u] = win[NW - 1 - u] && keep[u];
    end
  end

  function automatic logic [FH_W-1:0] rotl_len(input logic [FH_W-1:0] x, input int unsigned a, input int unsigned len);
    logic [FH_W-1:0] msk;
    msk = FH_W'((32'd1 << len) - 32'd1);
    return a == 0 ? x : (((x << a) | (x >> (len - a))) & msk);
  endfunction

  // Ref: HistRing::push, folded histories
  always_comb begin
    h_next      = h;
    h_next.ring = ring_new;
    h_next.head = head_new;
    for (int k = 0; k < FH_K; k++) begin
      for (int i = 0; i < TN; i++) begin
        logic [FH_W-1:0] acc;
        acc = rotl_len(h.fh[k][i], int'(n) % fh_len(k, i), fh_len(k, i));
        for (int u = 0; u < NW; u++) begin
          acc = acc ^ rotl_len(FH_W'(din[u]) ^ (FH_W'(outw[i][u]) << (ghr_len(i) % fh_len(k, i))),
                               u % fh_len(k, i), fh_len(k, i));
        end
        h_next.fh[k][i] = acc;
      end
    end
  end

endmodule

`default_nettype wire
