// Ref: front-end/BPU/BPU_pipe.h  class BpuPipe (BPU_PIPE=3: S0 uBTB, S1 L1 / array read, S2 compare)
`default_nettype none

// Pipelined branch prediction unit (docs/analysis/bpu-pipe-rtl.md).  One fetch block per cycle:
//   S0  pc register -> uBTB lookup -> next pc, speculative history / RAS push, TAGE index generation, the block's
//       address goes to the fetch-address queue;
//   S1  the block's slots read the main predictor arrays (type, TAGE, BTB, ITT); the L1 table (512 x 2) is read and may
//       replace the S0 guess (one bubble);
//   S2  compare / select on the registered array data: the final prediction goes to the PTAB and is compared with the
//       guess (override = squash the younger block, restart S0, two bubbles).
// History repair: the history checkpoint (and epoch) of every block travels to the back-end FTQ; a back-end branch
// mispredict returns it, a predecode flush uses the PDCKPT queue.
module bpu import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic [31:0]         refetch_address,
  input  logic                refetch_pd,
  input  logic                icache_read_ready,
  input  logic [7:0]          ptab_size,
  // repair information of a back-end branch mispredict
  input  logic                rf_valid,
  input  logic [HCK_W-1:0]    rf_ck,
  input  logic [EPOCH_W-1:0]  rf_epoch,
  input  logic [2:0]          rf_type,
  input  logic [31:0]         rf_pc,
  // result of the predecode check of the previous cycle
  input  logic                pd_valid,
  input  logic                pd_flush,
  input  logic                pd_hv,
  input  logic [HSYM_W-1:0]   pd_hbits,
  input  logic [1:0]          pd_ras_op,
  input  logic [31:0]         pd_ras_val,
  // commit stream
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [31:0]         base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [31:0]         target     [NCOMMIT],
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [NCOMMIT-1:0]  alt_pred,
  input  logic [PCPN_W-1:0]   pcpn       [NCOMMIT],
  input  logic [T_TAG_W-1:0]  tags       [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs       [NCOMMIT][TN],
  // S0: block address to the fetch-address queue
  output logic                icache_read_valid,
  output logic [31:0]         fetch_address,
  // S2: override of the younger block (the front end drops its fetch address)
  output logic                override_valid,
  output logic                override_squash,
  // S2: prediction written into the PTAB
  output logic                ptab_write_enable,
  output logic [31:0]         ptab_base_pc,
  output logic [31:0]         predict_next_fetch_address,
  output logic [NLANE-1:0]    out_pred_dir,
  output logic [NLANE-1:0]    out_alt_pred,
  output logic [PCPN_W-1:0]   out_pcpn     [NLANE],
  output logic [PCPN_W-1:0]   out_altpcpn  [NLANE],
  output logic [T_TAG_W-1:0]  out_tage_tags [NLANE][TN],
  output logic [T_IDX_W-1:0]  out_tage_idxs [NLANE][TN],
  output logic [HCK_W-1:0]    out_ck,
  output logic [EPOCH_W-1:0]  out_epoch
);

  // ---- stage registers ----
  logic [31:0]        pc_q, pc_d;
  blk_t               r0_q, r0_d, r1_q, r1_d;
  tix_all_t           r0_tix_q, r1_tix_q;
  raw_all_t           r1_raw_q;
  logic [EPOCH_W-1:0] epoch_q, epoch_d;

  // ---- S0 ----
  ck_t         spec_ck, spec1_ck, s0_ck;
  logic        spec_ras_nonempty, spec1_ras_nonempty, s0_ras_nonempty;
  logic [31:0] spec_ras_top, spec1_ras_top, s0_ras_top;
  fh_t         spec_fh, spec1_fh, s0_fh;
  tix_all_t    s0_tix;
  pred_t       g0;
  pred_t       g1;
  logic [31:0] s0_bnd, s0_base, pc1;

  // FE_RFAST bit0 / FE_BFAST: S0 looks up the block at the pc the redirect of this cycle produces, with the history /
  // RAS that redirect leaves, instead of the pc register and the registered speculative state.
  localparam bit FAST = (FE_RFAST & 1) != 0 || FE_BFAST != 0;
  always_comb begin
    s0_base         = FAST ? pc1 : pc_q;
    s0_ck           = FAST ? spec1_ck : spec_ck;
    s0_ras_nonempty = FAST ? spec1_ras_nonempty : spec_ras_nonempty;
    s0_ras_top      = FAST ? spec1_ras_top : spec_ras_top;
    s0_fh           = FAST ? spec1_fh : spec_fh;
  end

  assign s0_bnd = block_bnd(s0_base);
  bpu_stage0 u_stage0 (.base(s0_base), .spec_fh(s0_fh), .tix(s0_tix));

  bpu_ubtb u_ubtb (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .pred_dir, .target,
    .s0_base, .s0_bnd, .s0_ras_nonempty, .s0_ras_top, .s0_guess(g0),
    .s1_base(r0_q.base), .s1_bnd(block_bnd(r0_q.base)), .s1_ras_nonempty(r0_q.ck.r.cnt != '0),
    .s1_ras_top(r0_q.ck.r.top), .s1_guess(g1)
  );

  // ---- S1 / S2 arrays ----
  raw_all_t         s1_raw;
  logic [NBANK-1:0] s2_tg_pred, s2_tg_alt;
  logic [PCPN_W-1:0] s2_tg_pcpn [NBANK];
  logic [PCPN_W-1:0] s2_tg_altpcpn [NBANK];
  logic [NBANK-1:0] wr_valid;
  upd_ent_t         wr_ent [NBANK];
  logic [NBB-1:0]   bank_busy;

  bpu_banks u_banks (
    .clk, .rst_n, .s1_base(r0_q.base), .s1_tix(r0_tix_q), .s1_raw, .s2_raw(r1_raw_q), .s2_tix(r1_tix_q),
    .s2_pred(s2_tg_pred), .s2_alt(s2_tg_alt), .s2_pcpn(s2_tg_pcpn), .s2_altpcpn(s2_tg_altpcpn), .wr_valid, .wr_ent
  );

  always_comb begin
    bank_busy = '0;
    if (r0_q.valid) begin
      bank_busy[r0_q.base[6:5]] = 1'b1;
      bank_busy[(block_bnd(r0_q.base) - 32'd4) >> 5 & 32'(NBB - 1)] = 1'b1;
    end
  end

  bpu_updq u_updq (
    .clk, .rst_n, .upd_valid, .base_pc, .actual_dir, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .tags, .idxs,
    .bank_busy, .wr_valid, .wr_ent
  );

  // ---- S2 compare ----
  pred_t             fin;
  tp_entry_t         s2_ty    [NBANK][TP_WAYS];
  btb_ent_t          s2_btb   [NBANK][B_WAYS];
  itt_ent_t          s2_itt   [NBANK];
  tg_ix_t            s2_ix    [NBANK];

  always_comb begin
    for (int b = 0; b < NBANK; b++) begin
      s2_ty[b][0]  = r1_raw_q[b].ty[0];
      s2_ty[b][1]  = r1_raw_q[b].ty[1];
      for (int w = 0; w < B_WAYS; w++) s2_btb[b][w] = r1_raw_q[b].btb[w];
      s2_itt[b] = r1_raw_q[b].itt;
      s2_ix[b]  = r1_tix_q[b];
    end
  end

  bpu_main_sel u_sel (
    .base(r1_q.base), .ck_ras_nonempty(r1_q.ck.r.cnt != '0), .ck_ras_top(r1_q.ck.r.top), .ty_way(s2_ty),
    .tg_pred(s2_tg_pred), .tg_alt(s2_tg_alt), .tg_pcpn(s2_tg_pcpn), .tg_altpcpn(s2_tg_altpcpn), .ix(s2_ix),
    .btb_set(s2_btb), .itt(s2_itt), .pred(fin), .lane_dir(out_pred_dir), .lane_alt(out_alt_pred),
    .lane_pcpn(out_pcpn), .lane_altpcpn(out_altpcpn), .lane_tag(out_tage_tags), .lane_idx(out_tage_idxs)
  );

  // ---- decisions, speculative state, PDCKPT ----
  logic d_valid, ovr, squash, l1_ov, issue, fast, s0_go, pd_restore, rep_ok;
  logic pdq_have;
  ck_t  pd_ck;
  logic [1:0]  h_mode, r_mode, r_op;
  hist_ck_t    h_ck;
  logic        h_push_en;
  logic [HSYM_W-1:0] h_push_bits;
  ras_ck_t     r_ck;
  logic [31:0] r_val;

  bpu_ctl u_ctl (
    .refetch, .refetch_pd, .rf_valid, .rf_epoch_ok(rf_epoch == epoch_q), .pd_valid, .pd_flush, .pdq_have,
    .icache_read_ready, .ptab_size, .r0(r0_q), .r1(r1_q), .fin, .g1, .d_valid, .ovr, .squash, .l1_ov, .issue, .fast,
    .s0_go,
    .pd_restore, .rep_ok
  );

  logic        h2_en;
  logic [HSYM_W-1:0] h2_bits;
  logic [1:0]  r2_op;
  logic [31:0] r2_val;

  bpu_cmd u_cmd (
    .refetch, .pd_restore, .rep_ok, .ovr, .l1_ov, .issue, .s0_go, .pc(pc_q), .refetch_address, .g0, .g1, .fin,
    .r0(r0_q), .r1(r1_q), .pd_ck, .pd_hv, .pd_hbits, .pd_ras_op, .pd_ras_val, .rf_ck(hist_ck_t'(rf_ck)),
    .rf_type, .rf_pc, .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .pc1,
    .h2_en, .h2_bits, .r2_op, .r2_val, .pc_d
  );

  bpu_spec u_spec (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .target, .h_mode, .h_ck, .h_push_en, .h_push_bits,
    .r_mode, .r_ck, .r_op, .r_val, .h2_en, .h2_bits, .r2_op, .r2_val,
    .spec_ck, .spec_ras_nonempty, .spec_ras_top, .spec_fh, .spec1_ck, .spec1_ras_nonempty, .spec1_ras_top, .spec1_fh
  );

  bpu_pdq u_pdq (
    .clk, .rst_n, .pop(pd_valid), .push(d_valid), .push_ck(r1_q.ck), .clear(refetch), .head_valid(pdq_have),
    .head_ck(pd_ck)
  );

  // ---- next stage registers ----
  always_comb begin
    r0_d = '0;
    r0_d.valid = s0_go;
    r0_d.base  = s0_base;
    r0_d.g     = g0;
    r0_d.ck    = s0_ck;
    r1_d       = r0_q;
    r1_d.valid = r0_q.valid && !refetch && !ovr;
    if (l1_ov) r1_d.g = g1;
    epoch_d = epoch_q + EPOCH_W'(refetch && !pd_restore && !rep_ok);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_q    <= '0;
      r0_q    <= '0;
      r1_q    <= '0;
      epoch_q <= '0;
    end else begin
      pc_q    <= pc_d;
      r0_q    <= r0_d;
      r1_q    <= r1_d;
      epoch_q <= epoch_d;
    end
  end

  always_ff @(posedge clk) begin
    r0_tix_q <= s0_tix;
    r1_tix_q <= r0_tix_q;
    r1_raw_q <= s1_raw;
  end

  assign icache_read_valid          = s0_go;
  assign fetch_address              = s0_base;
  assign override_valid             = ovr;
  assign override_squash            = squash;
  assign ptab_write_enable          = d_valid;
  assign ptab_base_pc               = r1_q.base;
  assign predict_next_fetch_address = fin.next;
  assign out_ck                     = HCK_W'(r1_q.ck.h);
  assign out_epoch                  = epoch_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;   // S0 / S1 guess slot and type fields are statistics-only
  assign unused_ok = ^{g0.slot, g0.ty, g1.slot, g1.ty, fin.slot, fin.ty, fast, spec_ck.h.head, pc1};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
