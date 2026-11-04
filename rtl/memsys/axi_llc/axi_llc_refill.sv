`default_nettype none
// Ref: AXI_LLC.cpp  drive_mem_read_path, commit part (2908-3016): park dirty victim, write refill, answer master
// Refill engine, working on the MSHR entry `e_*` that holds refill data.  Two ticks per refill:
//   tick 1 (refill, not yet committed): the dirty victim snapshot is parked (write-back slot or queue) unless a
//          pending write to the victim line is still unresolved (stall) or the snapshot is already parked; then the
//          refill line is written into the tables (skipped if the table is busy, the park is kept) -> rcomm
//   tick 2 (committed, or bypass entry): response to the master when its response queue has room, entry freed
module axi_llc_refill
  import axi_llc_pkg::*;
(
  input  logic cs_v,
  input  logic e_bypass,
  input  logic e_rcomm,
  input  addr_t e_addr,
  input  logic [WB-1:0] e_way,
  input  line_t e_rdata,
  input  logic e_vdirty,
  input  addr_t e_vaddr,
  input  logic tbl_busy3,
  input  logic vwb_busy3,
  input  logic rvq_full_s2,
  input  logic [VQD:0] pr_vld,                 // victim snapshots already parked
  input  logic [VQD:0][31:0] pr_addr,
  // a write to the victim line is unresolved: lookup in flight, or write context waiting for its write-back
  input  logic lk_active_w,
  input  addr_t lk_line,
  input  logic [NW-1:0] wc_cpend,
  input  logic [NW-1:0][31:0] wc_line,
  input  logic acc_c,
  output logic park_go,
  output logic rcomm_go,
  output logic free_go,
  output tw_t tw,
  output logic enq_v,
  output line_t enq_data
);
  logic refill_path, parked, victim_waits, park_needed, park_blocked, ok;
  logic [NW-1:0] wc_hit;

  axi_llc_linecam #(.N(VQD + 1)) u_parked (.vld(pr_vld), .addr(pr_addr), .line(e_vaddr), .hit(parked));

  // the response queue is only involved in the second tick
  always_comb begin
    refill_path = cs_v && !e_rcomm && !e_bypass;
    enq_v = cs_v && !refill_path;
    enq_data = e_bypass ? e_rdata : resp_of(e_addr, e_rdata);
  end

  always_comb begin
    free_go = enq_v && acc_c;
  end

  // first tick: park the victim snapshot, write the refill
  always_comb begin
    for (int m = 0; m < NW; m++) wc_hit[m] = wc_cpend[m] && wc_line[m] == e_vaddr;
    victim_waits = (lk_active_w && lk_line == e_vaddr) || (|wc_hit);
    park_needed = e_vdirty && !victim_waits && !parked;
    park_blocked = park_needed && vwb_busy3 && rvq_full_s2;
    ok = !e_vdirty || (!victim_waits && !park_blocked);
    park_go = refill_path && ok && park_needed;
    rcomm_go = refill_path && ok && !tbl_busy3;
  end

  always_comb begin
    tw = '0;
    tw.line_en = rcomm_go;
    tw.repl_en = rcomm_go;
    tw.set = set_of(e_addr);
    tw.way = e_way;
    tw.data = e_rdata;
    tw.tag = tag_of(e_addr);
    tw.dirty = 1'b0;
    tw.repl = next_way(e_way);
  end
endmodule

`default_nettype wire
