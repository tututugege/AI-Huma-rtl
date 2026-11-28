// Ref: back-end/Ren.cpp  class Ren  (spec_RAT, arch_RAT; Ren::comb_rename reads, Ren::comb_fire writes/recovery)
`default_nettype none

// Speculative RAT (written at rename/walk, restored on mispredict/flush) and architectural RAT (written at commit).
// Stores narrow domain-local tags (TW = 8b for INT, 7b for FP) and computes only 2 next-state views:
//   1. spec_norm    (after all firing lanes)
//   2. ckpt_wr_rat  (after lanes 0..ckpt_lane, for the single checkpoint written this cycle)
// Replaces the previous 8x full-RAT snapshot array (520 -> 130 ren_last_write instances).
module ren_rat
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int NR = 3 * DECODE_WIDTH,    // read ports on spec_RAT
  parameter int ENTRIES = RAT_NUM,        // RAT entries (the FP RAT has FP_ARF_NUM, no pseudo entry)
  parameter bit FP = 1'b0,                // FP domain: local tag 0..FPRF_NUM-1, offset by FP_TAG_BASE
  parameter int TW = FP ? FP_PTR_W : $clog2(PRF_NUM),
  parameter bit PRE_OH = 1'b0             // 1: use pre-decoded one-hot rd_oh_in / wr_oh_in (2-stage Ren)
) (
  input  logic              clk,
  input  logic              rst_n,
  // spec RAT reads (value before this cycle's writes)
  /* verilator lint_off UNUSEDSIGNAL */
  input  areg_t             rd_areg [NR],
  input  logic [ENTRIES-1:0] rd_oh_in [NR],
  /* verilator lint_on UNUSEDSIGNAL */
  output preg_t             rd_preg [NR],
  // spec RAT writes from rename or walk, slot order = program order
  input  logic [N-1:0]      alloc_cand,
  input  logic [N-1:0]      fire,
  input  areg_t             alloc_areg [N],
  input  logic [ENTRIES-1:0] wr_oh_in [N],
  input  logic              use_wr_oh,
  input  preg_t             alloc_preg [N],
  // single checkpoint lane (one-hot) selected by ren_ckpt_ctl; snapshot is pipelined by 1 cycle
  input  logic              ckpt_wr_en,
  input  logic [N-1:0]      ckpt_wr_lane_oh,
  // arch RAT writes from commit
  input  logic [C-1:0]      reclaim,
  input  areg_t             commit_areg [C],
  input  preg_t             commit_preg [C],
  // recovery
  input  logic              flush,
  input  logic              mispred,
  input  logic              ckpt_hit,         // 1: restore ckpt_rat; 0: restore arch_d (then walk)
  input  logic [ENTRIES-1:0][TW-1:0] ckpt_rat,
  // single checkpoint snapshot (pipelined 1 cycle: valid on T+1 for u_ckpt write)
  output logic [ENTRIES-1:0][TW-1:0] ckpt_wr_rat
);

  typedef logic [TW-1:0] tag_t;
  typedef logic [ENTRIES-1:0][TW-1:0] ent_t;
  ent_t spec_q, spec_d, arch_q, arch_d, spec_norm;

  function automatic ent_t reset_rat();
    ent_t r;
    for (int i = 0; i < ENTRIES; i++) r[i] = tag_t'(i);
    return r;
  endfunction

  function automatic tag_t to_local(input preg_t p);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [PRF_IDX_WIDTH-1:0] d;
    /* verilator lint_on UNUSEDSIGNAL */
    d = FP ? (p - preg_t'(FP_TAG_BASE)) : p;
    return d[TW-1:0];
  endfunction

  function automatic preg_t to_global(input tag_t t);
    return FP ? (preg_t'(FP_TAG_BASE) + preg_t'(t)) : preg_t'(t);
  endfunction

  tag_t spec_entry [ENTRIES];
  tag_t alloc_tag [N];
  tag_t commit_tag [C];

  for (genvar e = 0; e < ENTRIES; e++) begin : g_entry_view
    assign spec_entry[e] = spec_q[e];
  end
  for (genvar j = 0; j < N; j++) begin : g_alloc_tag
    assign alloc_tag[j] = to_local(alloc_preg[j]);
  end
  for (genvar k = 0; k < C; k++) begin : g_commit_tag
    assign commit_tag[k] = to_local(commit_preg[k]);
  end

  // ---- reads: one-hot decode of areg (or pre-decoded rd_oh_in), AND-OR over narrow TW-bit RAT entries ----
  for (genvar r = 0; r < NR; r++) begin : g_read
    logic [ENTRIES-1:0] sel;
    tag_t               rd_tag;
    if (PRE_OH) begin : g_pre_rd
      assign sel = rd_oh_in[r];
    end else begin : g_dec_rd
      for (genvar e = 0; e < ENTRIES; e++) begin : g_dec
        assign sel[e] = (rd_areg[r] == areg_t'(e));
      end
    end
    ttg_onehot_mux #(.N(ENTRIES), .W(TW)) u_rd (.sel(sel), .data(spec_entry), .out(rd_tag));
    assign rd_preg[r] = (|sel) ? to_global(rd_tag) : '0;
  end

  // ---- 1-cycle pipelined checkpoint snapshot (branch cannot mispredict at T+1, so T+1 write is 0-cycle transparent) ----
  ent_t         ck_spec_q;
  logic [N-1:0] ck_lane_oh_q, ck_alloc_cand_q;
  areg_t        ck_alloc_areg_q [N];
  tag_t         ck_alloc_tag_q [N];

  always_ff @(posedge clk) begin
    if (ckpt_wr_en) begin
      ck_spec_q       <= spec_q;
      ck_lane_oh_q    <= ckpt_wr_lane_oh;
      ck_alloc_cand_q <= alloc_cand;
      ck_alloc_areg_q <= alloc_areg;
      ck_alloc_tag_q  <= alloc_tag;
    end
  end

  logic [N-1:0] ckpt_prefix;
  for (genvar j = 0; j < N; j++) begin : g_ck_pref
    assign ckpt_prefix[j] = |ck_lane_oh_q[N-1:j];
  end

  // ---- normal next spec RAT (T) and pipelined checkpoint RAT (T+1) ----
  for (genvar e = 0; e < ENTRIES; e++) begin : g_spec_wr
    logic [N-1:0] hit_norm, hit_ck;
    logic         any_norm, any_ck;
    tag_t         val_norm, val_ck;
    for (genvar j = 0; j < N; j++) begin : g_hit
      logic match_e;
      assign match_e     = alloc_cand[j] & ((PRE_OH && use_wr_oh) ? wr_oh_in[j][e] : (alloc_areg[j] == areg_t'(e)));
      assign hit_norm[j] = fire[j] & match_e;
      assign hit_ck[j]   = ckpt_prefix[j] & ck_alloc_cand_q[j] & (ck_alloc_areg_q[j] == areg_t'(e));
    end
    ren_last_write #(.N(N), .W(TW)) u_lw_norm (.hit(hit_norm), .data(alloc_tag),      .any(any_norm), .value(val_norm));
    ren_last_write #(.N(N), .W(TW)) u_lw_ck   (.hit(hit_ck),   .data(ck_alloc_tag_q), .any(any_ck),   .value(val_ck));
    assign spec_norm[e]   = any_norm ? val_norm : spec_q[e];
    assign ckpt_wr_rat[e] = any_ck   ? val_ck   : ck_spec_q[e];
  end

  // ---- arch RAT: commit writes, later commit slot wins ----
  for (genvar e = 0; e < ENTRIES; e++) begin : g_arch
    logic [C-1:0] hit;
    logic         hit_any;
    tag_t         hit_value;
    for (genvar k = 0; k < C; k++) begin : g_hit
      assign hit[k] = reclaim[k] & (commit_areg[k] == areg_t'(e));
    end
    ren_last_write #(.N(C), .W(TW)) u_lw (.hit(hit), .data(commit_tag), .any(hit_any), .value(hit_value));
    assign arch_d[e] = hit_any ? hit_value : arch_q[e];
  end

  // ---- spec RAT next state. Priority: flush > mispredict > normal rename/walk writes ----
  always_comb begin
    if (flush)         spec_d = arch_d;
    else if (mispred)  spec_d = ckpt_hit ? ckpt_rat : arch_d;
    else               spec_d = spec_norm;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spec_q <= reset_rat();
      arch_q <= reset_rat();
    end else begin
      spec_q <= spec_d;
      arch_q <= arch_d;
    end
  end

  // lint sink (Verilator ignores unused_* names): upper bits of global preg inputs are domain constants
  logic unused_hi;
  always_comb begin
    unused_hi = 1'b0;
    for (int j = 0; j < N; j++) unused_hi ^= ^alloc_preg[j];
    for (int k = 0; k < C; k++) unused_hi ^= ^commit_preg[k];
  end

endmodule

`default_nettype wire
