// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (StqEntry: store_state machine + data fields)
`default_nettype none

// One STQ entry.  Same organisation as lsu_ldq_ent: events in stage order B C E F G I1 I2 K N, a state chain,
// and one write rule per data field (docs/analysis/lsu-structure.md section 2).  The replay wait is kept out of the
// field bundle (the N-stage decision reads the bundle and writes the wait).
module lsu_stq_ent
  import lsu_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cm_go,                // B  ROB committed this store
  input  logic        flush,                // B  rob flush: the committed store is cancelled
  input  logic        mm_go,                // C  MMIO store response
  input  stq_dc_t     dc_ev,                // E  DCache store response
  input  logic        wk_go,                // E  MSHR fill wake-up: replay wait cleared
  input  stq_wb_t     wb_ev,                // F  written back (SC verdict)
  input  stq_ex_t     ex_ev,                // G  STD / STA
  input  stq_tr_t     tr_ev,                // I1 MMU response
  input  stq_tw_t     tw_ev,                // I2 wait_mmu window processing
  input  stq_al_t     al_ev,                // K  allocation
  input  logic        clr_win,              // L  entry is inside the start-of-cycle STQ window: br_mask is cleared
  input  logic [BRW-1:0] clear_mask,
  input  stq_is_t     is_ev,                // N  committed-store window decision
  output st_state_t   st_cur,                 // start of cycle
  output st_state_t   st_dc,                // after B, C, E response
  output st_state_t   st_exe,               // after F, G
  output st_state_t   st_tlb,               // after I1
  output st_state_t   st_win,               // after I2
  output st_state_t   st_al,                // after K
  output st_state_t   st_nx,                // after N: next state
  output stq_fld_t    fld_cur,
  output stq_fld_t    fld_e,                // value after this cycle's writes
  output logic [RWW-1:0] wait_dc,           // replay wait after the E response (input of the wake-up)
  output logic [RWW-1:0] wait_n,            // replay wait as seen by N (after wake-up and allocation)
  output logic [BRW-1:0] br_al              // br_mask after K (before clear_mask): mispredict truncation
);

  st_state_t st_cm, st_mm, st_wb;
  st_state_t st_reg_q;
  stq_fld_t  fld_reg_q;
  logic [RWW-1:0] wait_reg_q;
  logic      to_done, pf_i1, dv_g;

  assign st_cur  = st_reg_q;
  assign fld_cur = fld_reg_q;

  // ---- state chain ----
  assign to_done = flush || (fld_cur.lrsc && !fld_cur.sc_pass);
  assign pf_i1   = fld_cur.pf || (tr_ev.go && tr_ev.res == MMU_PAGE_FAULT);
  assign dv_g    = fld_cur.data_valid || ex_ev.std_go;
  always_comb begin
    st_cm  = cm_go ? (to_done ? ST_DONE : ST_COMMITTED) : st_cur;
    st_mm  = mm_go ? ST_DONE : st_cm;
    st_dc  = dc_ev.go ? (dc_ev.hit ? ST_DONE : ST_COMMITTED) : st_mm;
    st_wb  = wb_ev.go ? ST_WAIT_COMMIT : st_dc;
    st_exe = ex_ev.sta_go ? ST_WAIT_TLB : (ex_ev.std_rdy ? ST_READY : st_wb);
    st_tlb = st_exe;
    if (tr_ev.go) begin
      case (tr_ev.res)
        MMU_HIT:        st_tlb = dv_g ? ST_WAIT_DONE : ST_WAIT_DATA;
        MMU_PAGE_FAULT: st_tlb = ST_WAIT_DONE;
        MMU_MISS:       st_tlb = ST_WAIT_TLB_RETRY;
        default:        st_tlb = st_exe;
      endcase
    end
    st_win = st_tlb;
    if (tw_ev.retry) st_win = ST_WAIT_TLB;
    if (tw_ev.done)  st_win = pf_i1 ? ST_PAGE_FAULT : ST_READY;
    st_al  = al_ev.go ? ST_ALLOCATED : st_win;
    st_nx  = st_al;
    if (is_ev.mm)  st_nx = ST_WAIT_MMIO_RESP;
    if (is_ev.sup) st_nx = ST_DONE;
    if (is_ev.iss) st_nx = ST_WAIT_DCACHE_RESP;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st_reg_q <= ST_EMPTY;
    else        st_reg_q <= st_nx;
  end

  // ---- data fields: write enable / write data ----
  logic           supp_we, supp_wd, scp_we, scp_wd, dv_we, pv_we, pv_wd, pf_we, pf_wd, mmio_we, mmio_wd;
  logic           lrsc_we, lrsc_wd, rep_we, wait_we, brm_we, tr_hit;
  logic [1:0]     rep_wd;
  logic [RWW-1:0] w_dc, w_wk, w_n, wait_wd;
  logic [BRW-1:0] brm_wd;

  assign tr_hit  = tr_ev.go && tr_ev.res == MMU_HIT;
  // suppress: B (cancelled commit) -> F (SC verdict) -> K (clear)
  assign supp_we = (cm_go && to_done) || wb_ev.sc_upd || al_ev.go;
  assign supp_wd = al_ev.go ? 1'b0 : (wb_ev.sc_upd ? !wb_ev.pass : 1'b1);
  assign scp_we  = wb_ev.sc_upd || al_ev.go;
  assign scp_wd  = al_ev.go ? 1'b0 : wb_ev.pass;
  assign dv_we   = ex_ev.std_go || al_ev.go;
  assign pv_we   = ex_ev.sta_go || tr_hit || al_ev.go;           // STA clears, the MMU hit of the same cycle sets
  assign pv_wd   = !al_ev.go && tr_hit;
  assign pf_we   = (tr_ev.go && tr_ev.res == MMU_PAGE_FAULT) || al_ev.go;
  assign pf_wd   = !al_ev.go;
  assign mmio_we = tr_hit || al_ev.go;
  assign mmio_wd = !al_ev.go && is_mmio_addr(tr_ev.paddr);
  assign lrsc_we = ex_ev.sta_go || al_ev.go;
  assign lrsc_wd = !al_ev.go && ex_ev.lrsc;
  assign rep_we  = dc_ev.go || al_ev.go;
  assign rep_wd  = al_ev.go ? REPLAY_HIT : dc_ev.rp;
  // wait: E response -> E wake-up -> K (clear) -> N (suppress clears, candidates count down)
  assign w_dc    = dc_ev.go ? ((!dc_ev.hit && dc_ev.rp[1]) ? REPLAY_WAIT : '0) : wait_reg_q;
  assign w_wk    = wk_go ? '0 : w_dc;
  assign w_n     = al_ev.go ? '0 : w_wk;
  assign wait_dc = w_dc;
  assign wait_n  = w_n;
  assign wait_we = dc_ev.go || wk_go || al_ev.go || is_ev.sup || is_ev.dec;
  assign wait_wd = is_ev.sup ? '0 : (is_ev.dec ? w_n - RWW'(1) : w_n);
  // br_mask: K, then clear_mask for entries that were in the window at the start of the cycle
  assign br_al   = al_ev.go ? al_ev.br_mask : fld_cur.br_mask;
  assign brm_we  = al_ev.go || (clr_win && clear_mask != '0);
  assign brm_wd  = clr_win ? br_al & ~clear_mask : br_al;

  always_ff @(posedge clk) begin
    if (wait_we) wait_reg_q <= wait_wd;
  end

  always_ff @(posedge clk) begin
    if (ex_ev.std_go) fld_reg_q.data  <= ex_ev.data;
    if (ex_ev.sta_go) begin
      fld_reg_q.vaddr <= ex_ev.vaddr;
      fld_reg_q.func3 <= ex_ev.func3;
      fld_reg_q.dest  <= ex_ev.dest;
    end
    if (tr_hit) fld_reg_q.paddr <= tr_ev.paddr;
    if (al_ev.go) begin
      fld_reg_q.rob_idx  <= al_ev.rob_idx;
      fld_reg_q.rob_flag <= al_ev.rob_flag;
    end
    if (supp_we) fld_reg_q.suppress    <= supp_wd;
    if (scp_we)  fld_reg_q.sc_pass     <= scp_wd;
    if (dv_we)   fld_reg_q.data_valid  <= !al_ev.go;
    if (pv_we)   fld_reg_q.paddr_valid <= pv_wd;
    if (pf_we)   fld_reg_q.pf          <= pf_wd;
    if (mmio_we) fld_reg_q.mmio        <= mmio_wd;
    if (lrsc_we) fld_reg_q.lrsc        <= lrsc_wd;
    if (rep_we)  fld_reg_q.replay      <= rep_wd;
    if (brm_we)  fld_reg_q.br_mask     <= brm_wd;
  end

  always_comb begin
    fld_e = fld_cur;
    if (ex_ev.std_go) fld_e.data = ex_ev.data;
    if (ex_ev.sta_go) begin
      fld_e.vaddr = ex_ev.vaddr;
      fld_e.func3 = ex_ev.func3;
      fld_e.dest  = ex_ev.dest;
    end
    if (tr_hit) fld_e.paddr = tr_ev.paddr;
    if (al_ev.go) begin
      fld_e.rob_idx  = al_ev.rob_idx;
      fld_e.rob_flag = al_ev.rob_flag;
    end
    if (supp_we) fld_e.suppress    = supp_wd;
    if (scp_we)  fld_e.sc_pass     = scp_wd;
    if (dv_we)   fld_e.data_valid  = !al_ev.go;
    if (pv_we)   fld_e.paddr_valid = pv_wd;
    if (pf_we)   fld_e.pf          = pf_wd;
    if (mmio_we) fld_e.mmio        = mmio_wd;
    if (lrsc_we) fld_e.lrsc        = lrsc_wd;
    if (rep_we)  fld_e.replay      = rep_wd;
    if (brm_we)  fld_e.br_mask     = brm_wd;
  end

endmodule

`default_nettype wire
