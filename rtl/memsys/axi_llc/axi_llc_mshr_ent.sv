`default_nettype none
// Ref: AXI_LLC.cpp  struct MSHR entry (mshr[slot]) of the miss status table
// One miss entry.  Life cycle:  alloc (lookup miss) -> memory read issued -> refill data arrived (rvalid) ->
// victim parked / refill written into the table (rcomm) -> answer to the master, entry freed.
// Bypass entries (uncached 4-byte reads) skip the table: the memory response is answered directly.
// vdirty/vaddr/vdata: snapshot of the dirty victim line that this refill will overwrite; vdone: its write-back
// has been answered by memory (the entry owned the write-back slot).
// is_write: refill of a partial-line write miss; the write data is merged into the refill line and the entry is
// freed in the same tick (no read response).
module axi_llc_mshr_ent
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  // allocation from the lookup (stage 3)
  input  logic alloc,
  input  logic a_bypass,
  input  logic a_is_write,
  input  addr_t a_addr,
  input  logic [WB-1:0] a_way,
  input  logic [7:0] a_size,
  input  logic [1:0] a_master,
  input  logic [3:0] a_id,
  input  logic a_vdirty,
  input  addr_t a_vaddr,
  input  line_t a_vdata,
  // write hit on the line set of the lookup: the line becomes the new victim snapshot of refills into that way
  input  logic [SB-1:0] lk_set,
  input  addr_t lk_line,
  input  logic vu_go,
  input  logic [WB-1:0] vu_way,
  input  line_t vu_data,
  // write-back owned by this slot answered (address of the write-back)
  input  addr_t own_addr,
  input  logic own_set,
  // memory read response / issue / refill progress (stage 4)
  input  logic resp_store,
  input  line_t resp_data,
  input  logic issue_set,
  input  logic rcomm_set,
  input  logic free,
  // state
  output logic valid_q,
  output logic valid_d,
  output logic bypass_q,
  output logic bypass_d,
  output logic is_write_q,
  output logic issued_q,
  output logic rvalid_q,
  output logic rcomm_q,
  output addr_t addr_q,
  output addr_t addr_d,
  output logic [WB-1:0] way_q,
  output logic [7:0] size_q,
  output logic [1:0] master_q,
  output logic [1:0] master_d,
  output logic [3:0] id_q,
  output line_t rdata_q,
  output logic vdirty_d,
  output logic vdone_o,
  output addr_t vaddr_d,
  output line_t vdata_d,
  // way reservation / victim-holder contributions
  output logic [WAYS-1:0] rsv_mask,
  output logic vh_cur,
  output logic vh_d,
  output logic vh_s2,                          // after the write-back answer of this tick, before stage 3
  output logic own_m,                          // dirty victim of the answered write-back (any vdone)
  output logic own_nd,                         // ... not yet marked done
  output addr_t vaddr_q
);
  logic issued_d, rvalid_d, rcomm_d, vdirty_q, vdone_q, vdone_d, vdone_s2, other_line, vu_hit;
  line_t vdata_q;

  // way reservation of the lookup set (old state only)
  always_comb begin
    other_line = valid_q && !bypass_q && !rcomm_q && set_of(addr_q) == lk_set && line_of(addr_q) != lk_line;
    rsv_mask = '0;
    if (other_line) rsv_mask[way_q] = 1'b1;
  end

  always_comb begin
    vu_hit = vu_go && other_line && !is_write_q && way_q == vu_way;
    valid_d = (valid_q && !free) || alloc;
    issued_d = (alloc ? 1'b0 : issued_q) || issue_set;
    rvalid_d = !alloc && (rvalid_q || resp_store);
    rcomm_d = !alloc && (resp_store ? bypass_q : (rcomm_q || rcomm_set));
    vdirty_d = alloc ? a_vdirty : (vdirty_q || vu_hit);
    vaddr_d = alloc ? a_vaddr : vu_hit ? lk_line : vaddr_q;
    vdata_d = alloc ? a_vdata : vu_hit ? vu_data : vdata_q;
    addr_d = alloc ? a_addr : addr_q;
    bypass_d = alloc ? a_bypass : bypass_q;
    master_d = alloc ? a_master : master_q;
    vdone_s2 = vdone_q || own_set;
    vdone_d = alloc ? !a_vdirty : (vu_hit ? 1'b0 : vdone_s2);
    vdone_o = vdone_d;
    vh_cur = valid_q && !bypass_q && vdirty_q && !rcomm_q && (rvalid_q || vdone_q);
    vh_s2 = valid_q && !bypass_q && vdirty_q && !rcomm_q && (rvalid_q || vdone_s2);
    vh_d = valid_d && !bypass_d && vdirty_d && !rcomm_d && (rvalid_d || vdone_d);
    own_m = valid_q && vdirty_q && vaddr_q == own_addr;
    own_nd = own_m && !vdone_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      issued_q <= 1'b0;
      rvalid_q <= 1'b0;
      rcomm_q <= 1'b0;
      vdirty_q <= 1'b0;
      vdone_q <= 1'b0;
    end else begin
      valid_q <= valid_d;
      issued_q <= issued_d;
      rvalid_q <= rvalid_d;
      rcomm_q <= rcomm_d;
      vdirty_q <= vdirty_d;
      vdone_q <= vdone_d;
    end
  end

  always_ff @(posedge clk) begin
    if (alloc) begin
      bypass_q <= a_bypass;
      is_write_q <= a_is_write;
      addr_q <= a_addr;
      way_q <= a_way;
      size_q <= a_size;
      master_q <= a_master;
      id_q <= a_id;
    end
    if (alloc || vu_hit) begin
      vaddr_q <= vaddr_d;
      vdata_q <= vdata_d;
    end
    if (resp_store) rdata_q <= resp_data;
  end
endmodule

`default_nettype wire
