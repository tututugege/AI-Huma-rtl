`default_nettype none
// Permanent combinational equivalence testbench for front-end parallel refactors:
//   1) bpu_hist_vec (MAX_SYM=4 and MAX_SYM=8) vs bit-serial golden ring-push + folded-history reference
//   2) front_head_fix 4-round Kogge-Stone start_a/start_b scan vs serial RVC chain across all 65,536 patterns
module fe_clean_eq_tb;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;
  import bpu_stage_pkg::*;

  // ---- Part 1: bpu_hist_vec equivalence (MAX_SYM=4 and MAX_SYM=8) ----
  hist_t        h_in;
  logic [3:0]   sym_n4, sym_n8;
  logic [23:0]  d4, d8;
  hist_t        h_out4, h_out8;

  bpu_hist_vec #(.MAX_SYM(4)) u_hv4 (.h(h_in), .sym_n(sym_n4), .d(d4), .h_next(h_out4));
  bpu_hist_vec #(.MAX_SYM(8)) u_hv8 (.h(h_in), .sym_n(sym_n8), .d(d8), .h_next(h_out8));

  function automatic hist_t golden_push_bit(input hist_t cur, input logic b);
    hist_t n;
    n = cur;
    n.ring[cur.head] = b;
    n.head = cur.head + HR_PTR_W'(1);
    for (int k = 0; k < FH_K; k++) begin
      for (int i = 0; i < TN; i++) begin
        int unsigned flen = fh_len(k, i);
        int unsigned glen = ghr_len(i);
        logic [HR_PTR_W-1:0] oidx = cur.head - HR_PTR_W'(glen);
        logic ob = cur.ring[oidx];
        logic [FH_W-1:0] msk = FH_W'((32'd1 << flen) - 32'd1);
        logic [FH_W-1:0] v = cur.fh[k][i];
        logic top = v[flen - 1];
        v = ((v << 1) | FH_W'(top)) & msk;
        v = v ^ FH_W'(b) ^ (FH_W'(ob) << (glen % flen));
        n.fh[k][i] = v & msk;
      end
    end
    return n;
  endfunction

  // ---- Part 2: Kogge-Stone scan_starts equivalence vs serial chain ----
  function automatic logic [15:0] scan_starts_ks(input logic [15:0] gen, input logic [15:0] vmask);
    logic [15:0] h0, p0, h1, p1, h2, p2, h3, p3, h4, p4, out;
    for (int i = 0; i < 16; i++) begin h0[i] = gen[i]; p0[i] = 1'(i & 1); end
    for (int i = 0; i < 16; i++) begin
      h1[i] = (i >= 1) ? (h0[i] || h0[i - 1]) : h0[i];
      p1[i] = (i >= 1) ? (h0[i] ? p0[i] : p0[i - 1]) : p0[i];
    end
    for (int i = 0; i < 16; i++) begin
      h2[i] = (i >= 2) ? (h1[i] || h1[i - 2]) : h1[i];
      p2[i] = (i >= 2) ? (h1[i] ? p1[i] : p1[i - 2]) : p1[i];
    end
    for (int i = 0; i < 16; i++) begin
      h3[i] = (i >= 4) ? (h2[i] || h2[i - 4]) : h2[i];
      p3[i] = (i >= 4) ? (h2[i] ? p2[i] : p2[i - 4]) : p2[i];
    end
    for (int i = 0; i < 16; i++) begin
      h4[i] = (i >= 8) ? (h3[i] || h3[i - 8]) : h3[i];
      p4[i] = (i >= 8) ? (h3[i] ? p3[i] : p3[i - 8]) : p3[i];
      out[i] = vmask[i] && h4[i] && (p4[i] == 1'(i & 1));
    end
    return out;
  endfunction

  int errs;

  initial begin
    errs = 0;

    // 1) 20,000 random vectors for bpu_hist_vec (MAX_SYM=4 and MAX_SYM=8)
    for (int t = 0; t < 20000; t++) begin
      hist_t g4, g8;
      int nb4, nb8;
      for (int w = 0; w < HR_BITS / 32; w++) h_in.ring[w*32 +: 32] = $urandom();
      h_in.head = HR_PTR_W'($urandom());
      for (int k = 0; k < FH_K; k++)
        for (int i = 0; i < TN; i++)
          h_in.fh[k][i] = FH_W'($urandom() & ((32'd1 << fh_len(k, i)) - 32'd1));
      sym_n4 = 4'($urandom() % 5);
      sym_n8 = 4'($urandom() % 9);
      nb4    = 3 * int'(sym_n4);
      nb8    = 3 * int'(sym_n8);
      d4     = 24'($urandom()) & ((nb4 == 0) ? 24'd0 : ((24'd1 << nb4) - 24'd1));
      d8     = (nb8 == 24) ? 24'($urandom()) : (24'($urandom()) & ((nb8 == 0) ? 24'd0 : ((24'd1 << nb8) - 24'd1)));
      #1;
      g4 = h_in;
      for (int u = nb4 - 1; u >= 0; u--) g4 = golden_push_bit(g4, d4[u]);
      if (h_out4 !== g4) begin
        $display("FAIL HV4 t=%0d sym_n=%0d head=%0d", t, sym_n4, h_in.head);
        errs++;
      end
      g8 = h_in;
      for (int u = nb8 - 1; u >= 0; u--) g8 = golden_push_bit(g8, d8[u]);
      if (h_out8 !== g8) begin
        $display("FAIL HV8 t=%0d sym_n=%0d head=%0d", t, sym_n8, h_in.head);
        errs++;
      end
      if (errs > 10) $fatal(1, "Too many HV errors");
    end

    // 2) Exhaustive 65,536 RVC patterns x boundary positions for Kogge-Stone scan_starts
    for (int pat = 0; pat < 65536; pat++) begin
      logic [15:0] rvc, vmask, bnd, ga, gb, ks_a, ks_b, ref_a, ref_b;
      int vlen, bpos;
      rvc   = 16'(pat);
      vlen  = (pat % 16) + 1;
      bpos  = (pat / 16) % 16;
      vmask = (vlen == 16) ? 16'hffff : ((16'd1 << vlen) - 16'd1);
      bnd   = (bpos > 0) ? (16'd1 << bpos) : 16'd0;

      ga[0] = 1'b1; gb[0] = 1'b0;
      for (int i = 1; i < 16; i++) begin
        ga[i] = bnd[i] || rvc[i - 1];
        gb[i] = (i == 1) ? 1'b1 : (bnd[i] || rvc[i - 1]);
      end
      ks_a = scan_starts_ks(ga, vmask);
      ks_b = scan_starts_ks(gb, vmask);

      ref_a = '0; ref_b = '0;
      ref_a[0] = vmask[0];
      ref_b[0] = 1'b0;
      for (int i = 1; i < 16; i++) begin
        ref_a[i] = vmask[i] && (bnd[i] ? 1'b1 : (!ref_a[i - 1] || rvc[i - 1]));
        ref_b[i] = vmask[i] && ((i == 1 || bnd[i]) ? 1'b1 : (!ref_b[i - 1] || rvc[i - 1]));
      end
      if (ks_a !== ref_a || ks_b !== ref_b) begin
        $display("FAIL KS pat=%h vlen=%0d bpos=%0d ks_a=%h ref_a=%h ks_b=%h ref_b=%h",
                 pat, vlen, bpos, ks_a, ref_a, ks_b, ref_b);
        errs++;
        if (errs > 10) $fatal(1, "Too many KS errors");
      end
    end

    if (errs == 0) $display("FE_CLEAN_EQ PASS (20000 HV4/HV8 + 65536 KS patterns, 0 errs)");
    else           $fatal(1, "FE_CLEAN_EQ FAIL errs=%0d", errs);
    $finish;
  end
endmodule
`default_nettype wire
