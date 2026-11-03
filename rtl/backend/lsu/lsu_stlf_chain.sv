// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_stlf: sequential scan of the STLF window with break + shared resources)
`default_nettype none

// Positions are processed in order; a position that cannot make progress stops the scan (C++ `break`).
// Shared resources: room in wait_dcache / finish (count + entries enqueued so far < LDQ_SIZE) and the single
// uncached unit (only the first MMIO load that may go can take it).
module lsu_stlf_chain
  import lsu_pkg::*;
(
  input  logic [WIN-1:0]   in_win,
  input  logic [WIN-1:0]   valid,               // queue entry valid
  input  logic [WIN-1:0]   is_empty,            // LDQ entry already Empty (flushed): just pop
  input  logic [WIN-1:0]   is_check,            // CheckStlf: run the check
  input  logic [WIN-1:0]   is_pre_dc,           // WaitDcache left over from a cycle where wait_dcache was full
  input  logic [WIN-1:0]   is_pre_fin,          // WaitFinish left over from a cycle where finish was full
  input  logic [WIN-1:0]   is_mmio,
  input  logic [WIN-1:0]   mmio_go,             // older_store_count == 0 and the load is the oldest unfinished
  input  logic [WIN-1:0]   res_retry,
  input  logic [WIN-1:0]   res_fwd,
  input  logic [RCW-1:0]   wd_count,
  input  logic [RCW-1:0]   fin_count,
  input  logic             unc_valid,
  output logic [WIN-1:0]   pop,
  output logic [WIN-1:0]   retry,
  output logic [WIN-1:0]   app_wd,
  output logic [WIN-1:0]   app_fin,
  output logic [WIN-1:0]   unc_start,
  output logic [WIN-1:0]   wr_result,           // forwarded data is written to the LDQ entry
  output logic [WIN-1:0]   st_chg,              // the LDQ state is rewritten ...
  output ld_state_t        st_new [WIN]         // ... to this
);

  logic           alive [WIN+1];
  logic [RCW-1:0] nwd [WIN+1], nfin [WIN+1];
  logic           unc [WIN+1];

  always_comb begin
    alive[0] = 1'b1;
    nwd[0]   = '0;
    nfin[0]  = '0;
    unc[0]   = unc_valid;
    for (int p = 0; p < WIN; p++) begin
      logic active, mm, mm_go, nm, nm_fwd, dcp, finp, retry_k, other, ok_dc, ok_fin;
      active  = alive[p] && in_win[p];
      mm      = is_check[p] && is_mmio[p];
      mm_go   = mm && mmio_go[p] && !unc[p];
      nm      = is_check[p] && !is_mmio[p];
      nm_fwd  = nm && res_fwd[p];
      dcp     = (nm && !res_retry[p] && !res_fwd[p]) || is_pre_dc[p];
      finp    = nm_fwd || is_pre_fin[p];
      retry_k = (mm && !mm_go) || (nm && res_retry[p]);
      other   = !(is_empty[p] || is_check[p] || is_pre_dc[p] || is_pre_fin[p]);
      ok_dc   = wd_count + nwd[p] < RCW'(LQ);
      ok_fin  = fin_count + nfin[p] < RCW'(LQ);

      app_wd[p]    = active && valid[p] && dcp && ok_dc;
      app_fin[p]   = active && valid[p] && finp && ok_fin;
      unc_start[p] = active && valid[p] && mm_go;
      retry[p]     = active && valid[p] && retry_k;
      pop[p]       = active && (!valid[p] || is_empty[p] || mm_go || retry_k || app_wd[p] || app_fin[p]);
      wr_result[p] = active && valid[p] && nm_fwd;
      st_chg[p]    = active && valid[p] && !is_empty[p] && !other;
      st_new[p]    = mm_go ? LD_WAIT_MMIO_RESP : retry_k ? LD_CHECK_STLF :
                     dcp ? (ok_dc ? LD_READY_TO_ISSUE : LD_WAIT_DCACHE) : (ok_fin ? LD_READY_TO_WB : LD_WAIT_FINISH);

      // the scan stops at a valid entry that is neither popped nor retried
      alive[p+1] = alive[p] && !(active && valid[p] && !pop[p]);
      nwd[p+1]   = nwd[p] + RCW'(app_wd[p]);
      nfin[p+1]  = nfin[p] + RCW'(app_fin[p]);
      unc[p+1]   = unc[p] || unc_start[p];
    end
  end

endmodule

`default_nettype wire
