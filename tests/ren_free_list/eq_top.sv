// Equivalence test of the merged rtl/backend/ren/ren_free_list.sv against copies of the two modules it replaced
// (ren_free_list_ref_int = INT ren_free_list, ren_free_list_ref_fp = ren_fp_free_list, both as of 2026-11-28), in
// both parameterisations (INT defaults; FP as ren_fp.sv instantiates it). Random inputs every cycle (64-bit
// xorshift; ring positions mostly inside the ring, sometimes any value; occasional reset); every output is compared
// every cycle. Prints the first mismatches or PASS with the cycle count.
`default_nettype none
module eq_top import ttg_cfg_pkg::*; import ren_pkg::*; #(parameter int NVEC = 1000000) ();
  localparam int N = DECODE_WIDTH, C = COMMIT_WIDTH, CW = $clog2(C + 1);
  logic clk = 1'b0;
  longint unsigned rs = 64'h9e3779b97f4a7c15;
  function automatic longint unsigned rnd();
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
  endfunction
  int nvec = 0, nerr = 0;

  // ---- shared random inputs ----
  logic rst_n, flush, mispred, ckpt_hit;
  logic [C-1:0] reclaim;
  logic [CW-1:0] reclaim_rank [C];
  logic [CW-1:0] reclaim_total, alloc_commit_total;
  preg_t reclaim_preg_i [C], reclaim_preg_f [C];
  preg_t head_next_i, ckpt_head_i;
  fp_ptr_t head_next_f, ckpt_head_f;

  always @(posedge clk) begin
    longint unsigned m;
    m = rnd();
    rst_n              <= (nvec < 3) ? 1'b0 : (m[9:0] != 10'd0);
    flush              <= (m[15:10] == 6'd0);
    mispred            <= (m[19:16] == 4'd0);
    ckpt_hit           <= m[20];
    reclaim            <= C'(rnd());
    reclaim_total      <= CW'(rnd() % (C + 1));
    alloc_commit_total <= CW'(rnd() % (C + 1));
    for (int k = 0; k < C; k++) begin
      reclaim_rank[k]   <= CW'(m[21] ? rnd() : k);
      reclaim_preg_i[k] <= m[22] ? preg_t'(rnd()) : preg_t'(rnd() % PRF_NUM);
      reclaim_preg_f[k] <= m[23] ? preg_t'(rnd()) : preg_t'(FP_TAG_BASE + rnd() % FPRF_NUM);
    end
    head_next_i <= m[24] ? preg_t'(rnd()) : preg_t'(rnd() % PRF_NUM);
    ckpt_head_i <= m[25] ? preg_t'(rnd()) : preg_t'(rnd() % PRF_NUM);
    head_next_f <= m[26] ? fp_ptr_t'(rnd()) : fp_ptr_t'(rnd() % FPRF_NUM);
    ckpt_head_f <= m[27] ? fp_ptr_t'(rnd()) : fp_ptr_t'(rnd() % FPRF_NUM);
  end

  // ---- INT: merged module (defaults) vs the old ren_free_list ----
  preg_t win_ia [N], win_ib [N], cnt_ia, cnt_ib, head_ia, head_ib;
  ren_free_list u_int_new (
    .clk, .rst_n, .head_next(head_next_i), .reclaim, .reclaim_rank, .reclaim_total, .alloc_commit_total,
    .reclaim_preg(reclaim_preg_i), .flush, .mispred, .ckpt_hit, .ckpt_head(ckpt_head_i),
    .window(win_ia), .free_count(cnt_ia), .head(head_ia));
  ren_free_list_ref_int u_int_ref (
    .clk, .rst_n, .head_next(head_next_i), .reclaim, .reclaim_rank, .reclaim_total, .alloc_commit_total,
    .reclaim_preg(reclaim_preg_i), .flush, .mispred, .ckpt_hit, .ckpt_head(ckpt_head_i),
    .window(win_ib), .free_count(cnt_ib), .head(head_ib));

  // ---- FP: merged module with ren_fp.sv's parameters vs the old ren_fp_free_list ----
  preg_t win_fa [N], win_fb [N];
  fp_ptr_t cnt_fa, cnt_fb, head_fa, head_fb;
  ren_free_list #(.NUM(FPN), .RESV(FP_ARF_NUM), .TAG_BASE(FP_TAG_BASE), .PORT_W(FP_PTR_W)) u_fp_new (
    .clk, .rst_n, .head_next(head_next_f), .reclaim, .reclaim_rank, .reclaim_total,
    .alloc_commit_total(reclaim_total),
    .reclaim_preg(reclaim_preg_f), .flush, .mispred, .ckpt_hit, .ckpt_head(ckpt_head_f),
    .window(win_fa), .free_count(cnt_fa), .head(head_fa));
  ren_free_list_ref_fp u_fp_ref (
    .clk, .rst_n, .head_next(head_next_f), .reclaim, .reclaim_rank, .reclaim_total,
    .reclaim_preg(reclaim_preg_f), .flush, .mispred, .ckpt_hit, .ckpt_head(ckpt_head_f),
    .window(win_fb), .free_count(cnt_fb), .head(head_fb));

  always @(negedge clk) begin
    if (nvec > 3) begin
      if (cnt_ia != cnt_ib || head_ia != head_ib) begin
        nerr++; if (nerr < 6) $display("MISMATCH INT cyc %0d count %0d/%0d head %0d/%0d", nvec, cnt_ia, cnt_ib, head_ia, head_ib);
      end
      if (cnt_fa != cnt_fb || head_fa != head_fb) begin
        nerr++; if (nerr < 6) $display("MISMATCH FP cyc %0d count %0d/%0d head %0d/%0d", nvec, cnt_fa, cnt_fb, head_fa, head_fb);
      end
      for (int k = 0; k < N; k++) begin
        if (win_ia[k] != win_ib[k]) begin nerr++; if (nerr < 6) $display("MISMATCH INT cyc %0d window[%0d]", nvec, k); end
        if (win_fa[k] != win_fb[k]) begin nerr++; if (nerr < 6) $display("MISMATCH FP cyc %0d window[%0d]", nvec, k); end
      end
    end
  end

  initial begin
    for (int k = 0; k <= NVEC; k++) begin
      #1 clk = 1'b1;
      #1 clk = 1'b0;
      nvec = k;
    end
    if (nerr == 0) $display("PASS ren_free_list: %0d cycles, INT and FP parameterisations equal to the old modules", NVEC);
    else $display("FAIL ren_free_list: %0d mismatches", nerr);
    $finish;
  end
endmodule
`default_nettype wire
