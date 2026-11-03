`default_nettype none
// Ref: AXI_Interconnect.cpp  AXI_Interconnect::seq  (llc_core_req_stage_ / llc_upstream_req /
//   llc_upstream_write_req handling)
// Capture slots (one per master), the single core stage that is presented to the LLC, the 6-port round-robin
//   dispatcher and the
// stalled-read preemption by a write.  Next state follows the C++ order inside one seq():
//   pop (LLC took the stage entry) -> preempt -> dispatch (stage empty) -> capture new requests into free slots.
module axi_ic_stage
  import axi_ic_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          phase0,
  // accepted this tick (axi_ic_rd / axi_ic_wr) with the request fields
  input  logic          rd_acc  [NR],
  input  logic [31:0]   rd_addr [NR],
  input  logic [7:0]    rd_size [NR],
  input  logic [3:0]    rd_id   [NR],
  input  logic          rd_byp  [NR],
  input  logic          wr_acc  [NW],
  input  logic [31:0]   wr_addr [NW],
  input  logic [7:0]    wr_size [NW],
  input  logic [3:0]    wr_id   [NW],
  input  logic          wr_byp  [NW],
  input  logic [511:0]  wr_data [NW],
  input  logic [63:0]   wr_strb [NW],
  // LLC readiness (final comb of the tick)
  input  logic          lo_rd_ready [NR],
  input  logic          lo_wr_ready [NW],
  // state visible to the rest of the interconnect
  output logic          up_v    [NR],
  output logic [31:0]   up_addr [NR],
  output logic [3:0]    up_id   [NR],
  output logic          stg_rd_v [NR],        // stage holds a read of master m
  output logic [3:0]    stg_rd_id,
  output logic          stg_rd_any,
  output logic [31:0]   stg_rd_addr,
  output logic          stg_wr_v [NW],
  // what the LLC sees
  output logic [31:0]   li_addr, output logic [7:0] li_size, output logic [3:0] li_id, output logic li_byp,
  output logic [511:0]  li_wdata, output logic [63:0] li_wstrb,
  // accepted flags for the master ports (comb_outputs of the NEXT tick)
  output logic          acc_o1_rd [NR],
  output logic [3:0]    acc_o1_id [NR],
  output logic          acc_o1_wr [NW]
);
  typedef struct packed {
    logic v;
    logic [31:0] addr;
    logic [7:0] size;
    logic [3:0] id;
    logic byp;
  } rd_slot_t;
  typedef struct packed {
    logic v;
    logic [31:0] addr;
    logic [7:0] size;
    logic [3:0] id;
    logic byp;
    logic [511:0] data;
    logic [63:0] strb;
  } wr_slot_t;
  typedef struct packed {
    logic v, is_wr;
    logic [1:0] master;
    logic [31:0] addr;
    logic [7:0] size;
    logic [3:0] id;
    logic byp;
    logic [511:0] data;
    logic [63:0] strb;
  } stage_t;

  rd_slot_t up_rd_q [NR];
  wr_slot_t up_wr_q [NW];
  stage_t   stg_q;
  logic [2:0] rr_q;               // llc_core_dispatch_rr_ (0..5)

  rd_slot_t up_rd_d [NR];
  wr_slot_t up_wr_d [NW];
  stage_t   stg_d;
  logic [2:0] rr_d;

  // ---------------- views ----------------
  for (genvar m = 0; m < NR; m++) begin : g_v
    assign up_v[m]    = up_rd_q[m].v;
    assign up_addr[m] = up_rd_q[m].addr;
    assign up_id[m]   = up_rd_q[m].id;
    assign stg_rd_v[m] = stg_q.v && !stg_q.is_wr && stg_q.master == 2'(m);
  end
  for (genvar w = 0; w < NW; w++) begin : g_w
    assign stg_wr_v[w] = stg_q.v && stg_q.is_wr && stg_q.master == 2'(w);
  end
  assign stg_rd_id   = stg_q.id;
  assign stg_rd_any  = stg_q.v && !stg_q.is_wr;
  assign stg_rd_addr = stg_q.addr;
  assign li_addr  = stg_q.addr;
  assign li_size  = stg_q.size;
  assign li_id    = stg_q.id;
  assign li_byp   = stg_q.byp;
  assign li_wdata = stg_q.data;
  assign li_wstrb = stg_q.strb;

  // ---------------- pop / preempt / dispatch ----------------
  stage_t stg_pop, stg_pre;
  rd_slot_t pre_rd [NR];
  wr_slot_t pre_wr [NW];
  logic [2:0] rr_pre;
  logic       pop;

  logic [NW-1:0] elig_w;
  logic          pre_en, pre_pick;
  always_comb begin
    pop = stg_q.v && (stg_q.is_wr ? lo_wr_ready[stg_q.master[0]] : lo_rd_ready[stg_q.master]);
    stg_pop = pop ? '0 : stg_q;
    // preempt: the stage read was not taken, its master slot is free and a write to ANOTHER line is waiting
    for (int w = 0; w < NW; w++) elig_w[w] = up_wr_q[w].v && (line64(up_wr_q[w].addr) != line64(stg_pop.addr));
    pre_en = stg_pop.v && !stg_pop.is_wr && !lo_rd_ready[stg_pop.master] && !up_rd_q[stg_pop.master].v && (|elig_w);
    // write master tried first = rr % 2
    pre_pick = rr_q[0] ? (elig_w[1] ? 1'b1 : 1'b0) : (elig_w[0] ? 1'b0 : 1'b1);
    for (int m = 0; m < NR; m++) pre_rd[m] = up_rd_q[m];
    for (int w = 0; w < NW; w++) pre_wr[w] = up_wr_q[w];
    stg_pre = stg_pop;
    rr_pre  = rr_q;
    if (pre_en) begin
      pre_rd[stg_pop.master] = '{v: 1'b1, addr: stg_pop.addr, size: stg_pop.size, id: stg_pop.id, byp: stg_pop.byp};
      stg_pre = '{v: 1'b1, is_wr: 1'b1, master: {1'b0, pre_pick}, addr: up_wr_q[pre_pick].addr,
                  size: up_wr_q[pre_pick].size, id: up_wr_q[pre_pick].id, byp: up_wr_q[pre_pick].byp,
                  data: up_wr_q[pre_pick].data, strb: up_wr_q[pre_pick].strb};
      pre_wr[pre_pick] = '0;
      rr_pre = 3'((NR + int'(pre_pick) + 1) % (NR + NW));
    end
  end

  // dispatch: first valid port in round-robin order starting at rr
  stage_t stg_dis;
  rd_slot_t dis_rd [NR];
  wr_slot_t dis_wr [NW];
  logic [2:0] rr_dis;
  logic [NR+NW-1:0] port_v, port_hi, port_sel;
  logic [NR+NW-1:0] hi_sel, lo_sel;
  logic hi_any, lo_any;

  always_comb begin
    for (int m = 0; m < NR; m++) port_v[m] = pre_rd[m].v;
    for (int w = 0; w < NW; w++) port_v[NR + w] = pre_wr[w].v;
    for (int p = 0; p < NR + NW; p++) port_hi[p] = (3'(p) >= rr_pre);
  end
  ttg_first_set #(.N(NR+NW)) u_hi (.req(port_v & port_hi), .onehot(hi_sel), .any(hi_any));
  ttg_first_set #(.N(NR+NW)) u_lo (.req(port_v), .onehot(lo_sel), .any(lo_any));
  assign port_sel = hi_any ? hi_sel : lo_sel;

  always_comb begin
    stg_dis = stg_pre;
    rr_dis  = rr_pre;
    for (int m = 0; m < NR; m++) dis_rd[m] = pre_rd[m];
    for (int w = 0; w < NW; w++) dis_wr[w] = pre_wr[w];
    if (!stg_pre.v && (hi_any || lo_any)) begin
      for (int m = 0; m < NR; m++) if (port_sel[m]) begin
        stg_dis = '{v: 1'b1, is_wr: 1'b0, master: 2'(m), addr: pre_rd[m].addr, size: pre_rd[m].size, id: pre_rd[m].id,
                    byp: pre_rd[m].byp, data: '0, strb: '0};
        dis_rd[m] = '0;
        rr_dis = 3'((m + 1) % (NR + NW));
      end
      for (int w = 0; w < NW; w++) if (port_sel[NR + w]) begin
        stg_dis = '{v: 1'b1, is_wr: 1'b1, master: 2'(w), addr: pre_wr[w].addr, size: pre_wr[w].size, id: pre_wr[w].id,
                    byp: pre_wr[w].byp, data: pre_wr[w].data, strb: pre_wr[w].strb};
        dis_wr[w] = '0;
        rr_dis = 3'((NR + w + 1) % (NR + NW));
      end
    end
  end

  // capture accepted requests into free slots (slot state after dispatch)
  always_comb begin
    stg_d = stg_dis;
    rr_d  = rr_dis;
    for (int m = 0; m < NR; m++) begin
      up_rd_d[m] = dis_rd[m];
      if (!dis_rd[m].v && rd_acc[m])
        up_rd_d[m] = '{v: 1'b1, addr: rd_addr[m], size: rd_size[m], id: rd_id[m], byp: rd_byp[m]};
    end
    for (int w = 0; w < NW; w++) begin
      up_wr_d[w] = dis_wr[w];
      if (!dis_wr[w].v && wr_acc[w])
        up_wr_d[w] = '{v: 1'b1, addr: wr_addr[w], size: wr_size[w], id: wr_id[w], byp: wr_byp[w],
                       data: wr_data[w], strb: wr_strb[w]};
    end
  end

  // ---------------- accepted flags ----------------
  // read_req_accepted[m] = capture happened this tick (slot free after dispatch); write: accepted whenever accept_c.
  // The CPU-boundary restore (restore_axi_cpu_boundary_state) replaces the flags of the NON-DCache masters at the
  //   end of the
  // 16th tick by the OR of the whole CPU cycle (id = last accepted), so on tick 0 their O1 value is the sticky one.
  logic          rd_new [NR];
  logic          nat_rd_q [NR], stk_rd_q [NR], stk_rd_d [NR];
  logic [3:0]    nat_id_q [NR], stk_id_q [NR], stk_id_d [NR];
  logic          nat_wr_q [NW], stk_wr_q [NW], stk_wr_d [NW];
  always_comb begin
    for (int m = 0; m < NR; m++) begin
      rd_new[m]   = !dis_rd[m].v && rd_acc[m];
      stk_rd_d[m] = (phase0 ? 1'b0 : stk_rd_q[m]) || rd_new[m];
      stk_id_d[m] = rd_new[m] ? rd_id[m] : (phase0 ? 4'd0 : stk_id_q[m]);
    end
    for (int w = 0; w < NW; w++) stk_wr_d[w] = (phase0 ? 1'b0 : stk_wr_q[w]) || wr_acc[w];
  end
  for (genvar m = 0; m < NR; m++) begin : g_o1r
    assign acc_o1_rd[m] = (m != MASTER_DCACHE_R && phase0) ? stk_rd_q[m] : nat_rd_q[m];
    assign acc_o1_id[m] = (m != MASTER_DCACHE_R && phase0) ? stk_id_q[m] : nat_id_q[m];
  end
  for (genvar w = 0; w < NW; w++) begin : g_o1w
    assign acc_o1_wr[w] = (w != MASTER_DCACHE_W && phase0) ? stk_wr_q[w] : nat_wr_q[w];
  end

  // ---------------- registers ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int m = 0; m < NR; m++) up_rd_q[m] <= '0;
      for (int w = 0; w < NW; w++) up_wr_q[w] <= '0;
      stg_q <= '0;
      rr_q  <= '0;
      for (int m = 0; m < NR; m++) begin
        nat_rd_q[m] <= 1'b0; nat_id_q[m] <= 4'd0; stk_rd_q[m] <= 1'b0; stk_id_q[m] <= 4'd0;
      end
      for (int w = 0; w < NW; w++) begin nat_wr_q[w] <= 1'b0; stk_wr_q[w] <= 1'b0; end
    end else begin
      for (int m = 0; m < NR; m++) up_rd_q[m] <= up_rd_d[m];
      for (int w = 0; w < NW; w++) up_wr_q[w] <= up_wr_d[w];
      stg_q <= stg_d;
      rr_q  <= rr_d;
      for (int m = 0; m < NR; m++) begin
        nat_rd_q[m] <= rd_new[m];
        nat_id_q[m] <= rd_new[m] ? rd_id[m] : 4'd0;
        stk_rd_q[m] <= stk_rd_d[m];
        stk_id_q[m] <= stk_id_d[m];
      end
      for (int w = 0; w < NW; w++) begin nat_wr_q[w] <= wr_acc[w]; stk_wr_q[w] <= stk_wr_d[w]; end
    end
  end

`ifndef SYNTHESIS
  // C++ pushes a second write into llc_upstream_write_q (never executed on the live path): not implemented.
  for (genvar w = 0; w < NW; w++) begin : g_as
    assert property (@(posedge clk) disable iff (!rst_n) !(wr_acc[w] && dis_wr[w].v))
      else $error("axi_ic_stage: write accepted into an occupied capture slot of master %0d (llc_upstream_write_q)", w);
  end
`endif
endmodule

`default_nettype wire
