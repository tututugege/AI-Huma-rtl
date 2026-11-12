// Ref: back-end/Ren.cpp  class Ren  (spec_RAT, arch_RAT; Ren::comb_rename reads, Ren::comb_fire writes/recovery)
`default_nettype none

// Speculative RAT (written at rename, restored on mispredict/flush) and architectural RAT (written at commit).
module ren_rat
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int NR = 3 * DECODE_WIDTH,    // read ports on spec_RAT
  parameter int ENTRIES = RAT_NUM,        // RAT entries (the FP RAT has FP_ARF_NUM, no pseudo entry)
  parameter bit FP = 1'b0                 // FP domain: reset value is tag FP_TAG_BASE + i
) (
  input  logic              clk,
  input  logic              rst_n,
  // spec RAT reads (value before this cycle's writes)
  input  areg_t             rd_areg [NR],
  output preg_t             rd_preg [NR],
  // spec RAT writes from rename-fire, slot order = program order
  input  logic [N-1:0]      alloc_fire,
  input  areg_t             alloc_areg [N],
  input  preg_t             alloc_preg [N],
  // arch RAT writes from commit
  input  logic [C-1:0]      reclaim,
  input  areg_t             commit_areg [C],
  input  preg_t             commit_preg [C],
  // recovery
  input  logic              flush,
  input  logic              mispred,
  input  logic [ENTRIES-1:0][PRF_IDX_WIDTH-1:0] ckpt_rat,           // RAT_checkpoint[dec_bcast.br_id] (old value)
  // snapshot[i]: spec RAT after slots 0..i have written (stored in the checkpoint of a branch in slot i)
  output logic [ENTRIES-1:0][PRF_IDX_WIDTH-1:0] snapshot [N],
  output logic [ENTRIES-1:0][PRF_IDX_WIDTH-1:0] spec_rat            // spec RAT as of the start of the cycle
);

  typedef logic [ENTRIES-1:0][PRF_IDX_WIDTH-1:0] ent_t;
  ent_t spec_q, spec_d, arch_q, arch_d;

  // reset value: integer register i -> preg i; FP register i -> tag FP_TAG_BASE + i (Ren::init)
  function automatic ent_t reset_rat();
    ent_t r;
    for (int i = 0; i < ENTRIES; i++) r[i] = preg_t'(FP ? FP_TAG_BASE + i : i);
    return r;
  endfunction
  preg_t spec_entry [ENTRIES];
  assign spec_rat = spec_q;

  // ---- reads: one-hot decode of the areg, AND-OR over the RAT entries (areg beyond the RAT reads 0) ----
  for (genvar e = 0; e < ENTRIES; e++) begin : g_entry_view
    assign spec_entry[e] = spec_q[e];
  end

  for (genvar r = 0; r < NR; r++) begin : g_read
    logic [ENTRIES-1:0] sel;
    for (genvar e = 0; e < ENTRIES; e++) begin : g_dec
      assign sel[e] = (rd_areg[r] == areg_t'(e));
    end
    ttg_onehot_mux #(.N(ENTRIES), .W(PRF_IDX_WIDTH)) u_rd (.sel(sel), .data(spec_entry), .out(rd_preg[r]));
  end

  // ---- spec RAT snapshots: per slot i and entry e, last writer among slots 0..i ----
  for (genvar i = 0; i < N; i++) begin : g_snap_slot
    for (genvar e = 0; e < ENTRIES; e++) begin : g_snap_entry
      logic [N-1:0] hit;
      logic         hit_any;
      preg_t        hit_value;
      for (genvar j = 0; j < N; j++) begin : g_hit
        if (j <= i) begin : g_older
          assign hit[j] = alloc_fire[j] & (alloc_areg[j] == areg_t'(e));
        end else begin : g_younger
          assign hit[j] = 1'b0;
        end
      end
      ren_last_write #(.N(N), .W(PRF_IDX_WIDTH)) u_lw (.hit(hit), .data(alloc_preg), .any(hit_any),
                                                       .value(hit_value));
      assign snapshot[i][e] = hit_any ? hit_value : spec_q[e];
    end
  end

  // ---- arch RAT: commit writes, later commit slot wins ----
  for (genvar e = 0; e < ENTRIES; e++) begin : g_arch
    logic [C-1:0] hit;
    logic         hit_any;
    preg_t        hit_value;
    for (genvar k = 0; k < C; k++) begin : g_hit
      assign hit[k] = reclaim[k] & (commit_areg[k] == areg_t'(e));
    end
    ren_last_write #(.N(C), .W(PRF_IDX_WIDTH)) u_lw (.hit(hit), .data(commit_preg), .any(hit_any),
                                                     .value(hit_value));
    assign arch_d[e] = hit_any ? hit_value : arch_q[e];
  end

  // ---- spec RAT next state. Priority (Ren::comb_fire): flush > mispredict > normal rename writes ----
  always_comb begin
    if (flush)         spec_d = arch_d;
    else if (mispred)  spec_d = ckpt_rat;
    else               spec_d = snapshot[N-1];
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

endmodule

`default_nettype wire
