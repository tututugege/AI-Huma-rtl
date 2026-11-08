// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LSU_MEMSPEC: SPD defer / release in comb_lsu2exe_p, violation check)
`default_nettype none

// Memory-dependence speculation of one LDQ entry, between the write-back step (P5) and the AGU arrival (P6):
//   P5  a load that passed an unknown-address store (spec) keeps its entry after the write-back: SPD (or RDY, second
//       pass, if a violation is already known); an SPD load with no unknown store older than itself is released to
//       WBP for the completion write-back.  Registered SPD entries and the direct write-backs of this cycle are
//       looked at, the WBP picks of this cycle are not.
//   P6  the STA arrivals of this cycle (rank from the head, 12-bit offset) are compared with the entry: an older store
//       whose address overlaps a spec load violates it (SPD: re-execute, otherwise the load replays after its first
//       write-back).  Loads that have not been written back keep their state.
module lp_ent_ms
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  lp_ld_st_t           st4,       // state after the write-back frees
  input  logic                wb_go,
  input  logic                wb_go_d,   // the write-back comes from the direct / L3 path (not a WBP pick)
  /* verilator lint_off UNUSEDSIGNAL */  // the entry view: only the speculation fields are read
  input  lp_ldq_t             f_q,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [SQW:0]        head_tag,
  input  logic [CNTW-1:0]     count_q,
  input  logic                unk_any,   // some store of the STQ ring has no address yet
  input  logic [SQW-1:0]      unk_rank,  // rank (from the head) of the oldest such store
  input  logic [NST-1:0]      sa_v,      // accepted STA arrivals of this cycle
  /* verilator lint_off UNUSEDSIGNAL */  // the STA view is used with LSU_MEMSPEC only
  input  logic [SQW-1:0]      sa_rank [NST],
  input  logic [11:0]         sa_voff [NST],
  input  logic [2:0]          sa_f3 [NST],
  /* verilator lint_on UNUSEDSIGNAL */
  output lp_ld_st_t           st4v,
  output logic                dfr,       // this write-back is deferred (the entry stays)
  output logic                sec4v,     // next value of `second`
  output logic                vio_n,     // next value of `vio`
  output logic                vio_new    // the entry became a violator in this cycle
);

  if (MS) begin : g_on
    lp_ld_st_t       st4r;
    logic            rel, sec4, v_elig;
    logic [NST-1:0]  ovl;
    logic [CNTW-1:0] older_e;
    always_comb begin
      dfr = wb_go && !f_q.second && f_q.spec && !f_q.pf && !f_q.mmio && !f_q.lrsc;
      older_e = older_cnt(f_q.snap_flag, f_q.snap_idx, head_tag[SQW], head_tag[SQW-1:0], count_q);
      st4r = st4;
      if (dfr) st4r = f_q.vio ? LS_RDY : LS_SPD;
      rel = st4r == LS_SPD && !(wb_go && !wb_go_d) && (!unk_any || older_e <= CNTW'(unk_rank));
      if (rel) st4r = LS_WBP;
      sec4 = f_q.second || (dfr && f_q.vio) || rel;
      v_elig = f_q.spec && !f_q.vio && !sec4 &&
               (st4r == LS_PIPE || st4r == LS_DCW || st4r == LS_WBP || st4r == LS_WB3 || st4r == LS_SPD);
      for (int k = 0; k < NST; k++)
        ovl[k] = sa_v[k] && CNTW'(sa_rank[k]) < older_e &&
                 rel12(f_q.vaddr[11:0], f_q.func3, sa_voff[k], sa_f3[k]) != 2'd0;
      vio_new = v_elig && (|ovl);
      st4v = (vio_new && st4r == LS_SPD) ? LS_RDY : st4r;
      sec4v = sec4 || (vio_new && st4r == LS_SPD);
      vio_n = f_q.vio || vio_new;
    end
  end else begin : g_off
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    assign unused = wb_go ^ wb_go_d ^ (^f_q) ^ (^head_tag) ^ (^count_q) ^ unk_any ^ (^unk_rank) ^ (^sa_v);
    /* verilator lint_on UNUSEDSIGNAL */
    assign st4v = st4;
    assign dfr = 1'b0;
    assign sec4v = f_q.second;
    assign vio_n = f_q.vio;
    assign vio_new = 1'b0;
  end

endmodule

`default_nettype wire
