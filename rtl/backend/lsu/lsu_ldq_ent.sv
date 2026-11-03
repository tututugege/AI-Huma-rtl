// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (LdqEntry: load_state machine + data fields)
`default_nettype none

// One LDQ entry.  The queue logic decides, per cycle, which events hit this entry (inputs *_ev, already qualified);
// the entry applies them in stage order (C D F G I1 I2 J K L M), so within one cycle an entry can travel through
// several states (a load: AGU -> WaitTlb -> WaitSTLF -> CheckStlf -> ReadyToIssue -> WaitDcacheResp).
// Data fields have one write stage each (docs/analysis/lsu-structure.md section 1); `fld_e` is the value after this
// cycle's writes (what later stages of the same cycle read), `fld_cur` the value at the start of the cycle.
// `result` is kept out of the field bundles: the forwarding scan (J) reads the bundle and writes `result`.
module lsu_ldq_ent
  import lsu_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  // events, in stage order
  input  ldq_mm_t     mm_ev,                // C  MMIO load response
  input  ldq_dc_t     dc_ev,                // D  DCache load response
  input  logic        wb_go,                // F  written back
  input  ldq_agu_t    agu_ev,               // G  address generated
  input  ldq_tr_t     tr_ev,                // I1 MMU response
  input  ldq_tw_t     tw_ev,                // I2 wait_mmu window processing
  input  ldq_sf_t     sf_ev,                // J  store-to-load forwarding scan
  input  ldq_al_t     al_ev,                // K  allocation
  input  logic        flush,                // L  rob flush
  input  logic        mispred,              // L  branch mispredict
  input  logic [BRW-1:0] dec_br_mask,
  input  logic [BRW-1:0] clear_mask,
  input  logic        iss_go,               // M  DCache request issued
  // state views
  output ld_state_t   st_cur,                 // start of cycle
  output ld_state_t   st_rsp,               // after C, D
  output ld_state_t   st_agu,               // after F, G
  output ld_state_t   st_tlb,               // after I1
  output ld_state_t   st_win,               // after I2
  output ld_state_t   st_fl,                // after K, L  (== Empty: entry is free / was killed)
  // data views
  output ldq_fld_t    fld_cur,
  output ldq_fld_t    fld_e,
  output logic [31:0] result_f              // result as seen by the write-back (after C, D)
);

  ld_state_t st_nx, st_wb, st_sf, st_al;
  ld_state_t st_reg_q;
  ldq_fld_t  fld_reg_q;
  logic [31:0] result_reg_q;

  assign st_cur  = st_reg_q;
  assign fld_cur = fld_reg_q;

  // ---- state machine: one rule per stage, later stages see the earlier results ----
  always_comb begin
    st_rsp = st_cur;
    if (mm_ev.go) st_rsp = LD_READY_TO_WB;
    if (dc_ev.go) st_rsp = dc_ev.hit ? LD_READY_TO_WB : LD_READY_TO_ISSUE;
    st_wb  = wb_go ? LD_EMPTY : st_rsp;
    st_agu = agu_ev.go ? LD_WAIT_TLB : st_wb;
    st_tlb = st_agu;
    if (tr_ev.go) begin
      case (tr_ev.res)
        MMU_HIT:        st_tlb = LD_WAIT_STLF;
        MMU_PAGE_FAULT: st_tlb = LD_WAIT_FINISH;
        MMU_MISS:       st_tlb = LD_WAIT_TLB_RETRY;
        default:        st_tlb = st_agu;
      endcase
    end
    st_win = st_tlb;
    if (tw_ev.retry) st_win = LD_WAIT_TLB;
    if (tw_ev.fin)   st_win = LD_PAGE_FAULT;
    if (tw_ev.stlf)  st_win = LD_CHECK_STLF;
    st_sf  = sf_ev.chg ? sf_ev.new_st : st_win;
    st_al  = al_ev.go ? LD_ALLOCATED : st_sf;
  end

  // ---- L: flush empties everything, a mispredict kills the entries whose (post-allocation) br_mask hits ----
  logic [BRW-1:0] brm_al;
  logic           killed;
  assign brm_al = al_ev.go ? al_ev.br_mask : fld_cur.br_mask;
  assign killed = mispred && st_al != LD_EMPTY && (brm_al & dec_br_mask) != '0;
  assign st_fl  = (flush || killed) ? LD_EMPTY : st_al;
  assign st_nx  = iss_go ? LD_WAIT_DCACHE_RESP : st_fl;

  always_ff @(posedge clk) begin
    if (!rst_n) st_reg_q <= LD_EMPTY;
    else        st_reg_q <= st_nx;
  end

  // ---- data fields: write enables / write data (docs/analysis/lsu-structure.md section 1) ----
  logic           res_we, replay_we, pf_set, pf_clr, brm_we;
  logic [31:0]    res_wd, res_cd;
  logic [1:0]     replay_wd;
  logic [BRW-1:0] brm_wd;

  assign res_cd    = mm_ev.go ? mm_ev.data : result_reg_q;                       // after C
  assign result_f  = (dc_ev.go && dc_ev.hit) ? dc_ev.data : res_cd;              // after D
  assign res_we    = mm_ev.go || (dc_ev.go && dc_ev.hit) || sf_ev.res_we;         // the three writers are exclusive
  assign res_wd    = sf_ev.res_we ? sf_ev.res : result_f;
  assign replay_we = dc_ev.go || al_ev.go;
  assign replay_wd = al_ev.go ? REPLAY_HIT : dc_ev.rp;
  assign pf_set    = tr_ev.go && tr_ev.res == MMU_PAGE_FAULT;
  assign pf_clr    = al_ev.go;
  assign brm_we    = al_ev.go || (st_cur != LD_EMPTY && clear_mask != '0);
  assign brm_wd    = (st_cur != LD_EMPTY) ? brm_al & ~clear_mask : brm_al;

  always_ff @(posedge clk) begin
    if (res_we) result_reg_q <= res_wd;
  end

  always_ff @(posedge clk) begin
    if (agu_ev.go) begin
      fld_reg_q.vaddr     <= agu_ev.vaddr;
      fld_reg_q.dest      <= agu_ev.dest;
      fld_reg_q.func3     <= agu_ev.func3;
      fld_reg_q.snap_idx  <= agu_ev.snap_idx;
      fld_reg_q.snap_flag <= agu_ev.snap_flag;
      fld_reg_q.lrsc      <= agu_ev.lrsc;
    end
    if (tr_ev.go && tr_ev.res == MMU_HIT) begin
      fld_reg_q.paddr <= tr_ev.paddr;
      fld_reg_q.mmio  <= is_mmio_addr(tr_ev.paddr);
    end
    if (al_ev.go) begin
      fld_reg_q.rob_idx  <= al_ev.rob_idx;
      fld_reg_q.rob_flag <= al_ev.rob_flag;
    end
    if (replay_we) fld_reg_q.replay <= replay_wd;
    if (pf_clr)    fld_reg_q.pf     <= 1'b0;
    else if (pf_set) fld_reg_q.pf   <= 1'b1;
    if (brm_we)    fld_reg_q.br_mask <= brm_wd;
  end

  // value after this cycle's writes
  always_comb begin
    fld_e         = fld_cur;
    if (agu_ev.go) begin
      fld_e.vaddr     = agu_ev.vaddr;
      fld_e.dest      = agu_ev.dest;
      fld_e.func3     = agu_ev.func3;
      fld_e.snap_idx  = agu_ev.snap_idx;
      fld_e.snap_flag = agu_ev.snap_flag;
      fld_e.lrsc      = agu_ev.lrsc;
    end
    if (tr_ev.go && tr_ev.res == MMU_HIT) begin
      fld_e.paddr = tr_ev.paddr;
      fld_e.mmio  = is_mmio_addr(tr_ev.paddr);
    end
    if (al_ev.go) begin
      fld_e.rob_idx  = al_ev.rob_idx;
      fld_e.rob_flag = al_ev.rob_flag;
    end
    if (replay_we) fld_e.replay = replay_wd;
    if (pf_clr)    fld_e.pf     = 1'b0;
    else if (pf_set) fld_e.pf   = 1'b1;
    if (brm_we)    fld_e.br_mask = brm_wd;
  end

endmodule

`default_nettype wire
