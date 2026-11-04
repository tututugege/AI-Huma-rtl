`default_nettype none
// Ref: AXI_LLC.cpp  mshr[] table: find_free_mshr, drive_mem_read_path (memory response, issue pick, refill pick)
// Miss status table: NMSHR entries plus the selection logic that is shared by all of them
//   * allocation goes to the first free entry (stage 3),
//   * the memory read response (id = slot) stores its data in the entry or, for a bypass read whose master can
//     take it, is answered directly (stage 4a),
//   * the memory read is issued for the first entry that was not issued yet; a bypass entry allocated in this
//     very tick may issue immediately when none is waiting (stage 4b),
//   * the refill engine works on the first entry with refill data (stage 4c); its fields are exported as `e_*`.
module axi_llc_mshr
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  // allocation (stage 3)
  input  logic alloc_go,
  input  logic a_bypass,
  input  addr_t a_addr,
  input  logic [WB-1:0] a_way,
  input  logic [7:0] a_size,
  input  logic [1:0] a_master,
  input  logic [3:0] a_id,
  input  logic a_vdirty,
  input  addr_t a_vaddr,
  input  line_t a_vdata,
  output logic free_any_cur,
  // lookup line (write-hit victim update, way reservation)
  input  logic [SB-1:0] lk_set,
  input  addr_t lk_line,
  input  logic vu_go,
  input  logic [WB-1:0] vu_way,
  input  line_t vu_data,
  output logic [WAYS-1:0] rsv_mask,
  // memory read response (stage 4a)
  input  logic mrr_v,
  input  logic [3:0] mrr_id,
  input  line_t mrr_data,
  input  logic resp_acc,                       // the master of a bypass response can take it now
  output logic resp_want,                      // bypass response to answer directly
  output logic [1:0] resp_master,
  output logic [3:0] resp_eid,
  output logic bad_resp,                       // response for a slot that is not in use
  // memory read request (stage 4b)
  input  logic mrd_ready,
  output logic mrd_v,
  output addr_t mrd_addr,
  output logic [7:0] mrd_size,
  output logic [3:0] mrd_id,
  // refill engine (stage 4c)
  input  logic rcomm_go,
  input  logic free_go,
  output logic cs_v,
  output logic [MIDW-1:0] cs_idx,
  output logic e_bypass,
  output logic e_rcomm,
  output addr_t e_addr,
  output logic [WB-1:0] e_way,
  output logic [1:0] e_master,
  output logic [3:0] e_id,
  output line_t e_rdata,
  output logic e_vdirty,
  output addr_t e_vaddr,
  output line_t e_vdata,
  // hazard lists
  output logic [NMSHR-1:0] vh_cur,               // refill data present, dirty victim snapshot not yet written
  output logic [NMSHR-1:0][31:0] vh_addr_cur,
  output logic [NMSHR-1:0] vh_d,
  output logic [NMSHR-1:0][31:0] vh_addr_d,
  output logic [NMSHR-1:0] ml_vld_cur,           // non-bypass entries and their line
  output logic [NMSHR-1:0][31:0] ml_line_cur,
  output logic [NMSHR-1:0] ml_vld_d,
  output logic [NMSHR-1:0][31:0] ml_line_d,
  output logic free_any_d,
  output logic [NR-1:0] has_master_d,
  // registers read by the interconnect
  output logic [NMSHR-1:0] hz_valid,
  output logic [NMSHR-1:0][1:0] hz_master,
  output logic [NMSHR-1:0][3:0] hz_id,
  output logic [NMSHR-1:0][31:0] hz_line
);
  logic [NMSHR-1:0] valid_q, valid_d, bypass_q, bypass_d, issued_q, rvalid_q, rcomm_q;
  logic [NMSHR-1:0] vdirty_d;
  addr_t addr_q [NMSHR];
  addr_t addr_d [NMSHR];
  addr_t vaddr_d [NMSHR];
  logic [WB-1:0] way_q [NMSHR];
  logic [7:0] size_q [NMSHR];
  logic [1:0] master_q [NMSHR];
  logic [1:0] master_d [NMSHR];
  logic [3:0] id_q [NMSHR];
  line_t rdata_q [NMSHR];
  line_t vdata_d [NMSHR];
  logic [WAYS-1:0] ent_rsv [NMSHR];
  addr_t vaddr_q [NMSHR];

  logic [NMSHR-1:0] free_oh, alloc_oh, resp_oh, iss_cand, iss_oh_q, iss_oh, cs_cand, cs_oh;
  logic [NMSHR-1:0] resp_store, free_a, issue_set, rcomm_set, free_c, free_any_vec;
  logic iss_any_q, direct;
  /* verilator lint_off UNUSEDSIGNAL */
  logic free_oh_any;                           // the free-slot search result is used through free_any_cur
  /* verilator lint_on UNUSEDSIGNAL */
  logic [MIDW-1:0] iss_idx;

  // ---------------- selection ----------------
  always_comb begin
    free_any_vec = ~valid_q;
    free_any_cur = |free_any_vec;
    for (int i = 0; i < NMSHR; i++) begin
      resp_oh[i] = mrr_v && !mrr_id[3] && mrr_id[MIDW-1:0] == MIDW'(i) && valid_q[i];
      iss_cand[i] = valid_q[i] && !issued_q[i];
      cs_cand[i] = valid_q[i] && rvalid_q[i];
    end
    bad_resp = mrr_v && !(|resp_oh);
    direct = alloc_go && a_bypass && !iss_any_q;
    iss_oh = iss_any_q ? iss_oh_q : (direct ? free_oh : '0);
    mrd_v = iss_any_q || direct;
    alloc_oh = alloc_go ? free_oh : '0;
    for (int i = 0; i < NMSHR; i++) begin
      free_a[i] = resp_oh[i] && bypass_q[i] && resp_acc;
      resp_store[i] = resp_oh[i] && !(bypass_q[i] && resp_acc);
      issue_set[i] = iss_oh[i] && mrd_ready;
      rcomm_set[i] = cs_oh[i] && rcomm_go;
      free_c[i] = cs_oh[i] && free_go;
    end
  end

  ttg_first_set #(.N(NMSHR)) u_free (.req(free_any_vec), .onehot(free_oh), .any(free_oh_any));
  ttg_first_set #(.N(NMSHR)) u_iss (.req(iss_cand), .onehot(iss_oh_q), .any(iss_any_q));
  ttg_first_set #(.N(NMSHR)) u_cs (.req(cs_cand), .onehot(cs_oh), .any(cs_v));
  ttg_onehot_to_idx #(.N(NMSHR), .IDXW(MIDW)) u_iss_idx (.onehot(iss_oh), .idx(iss_idx));
  ttg_onehot_to_idx #(.N(NMSHR), .IDXW(MIDW)) u_cs_idx (.onehot(cs_oh), .idx(cs_idx));

  // ---------------- entries ----------------
  for (genvar i = 0; i < NMSHR; i++) begin : g_ent
    axi_llc_mshr_ent u_ent (
      .clk(clk), .rst_n(rst_n),
      .alloc(alloc_oh[i]), .a_bypass(a_bypass), .a_addr(a_addr), .a_way(a_way), .a_size(a_size),
      .a_master(a_master), .a_id(a_id), .a_vdirty(a_vdirty), .a_vaddr(a_vaddr), .a_vdata(a_vdata),
      .lk_set(lk_set), .lk_line(lk_line), .vu_go(vu_go), .vu_way(vu_way), .vu_data(vu_data),
      .resp_store(resp_store[i]), .resp_data(mrr_data), .issue_set(issue_set[i]), .rcomm_set(rcomm_set[i]),
      .free(free_a[i] || free_c[i]),
      .valid_q(valid_q[i]), .valid_d(valid_d[i]), .bypass_q(bypass_q[i]), .bypass_d(bypass_d[i]),
      .issued_q(issued_q[i]),
      .rvalid_q(rvalid_q[i]), .rcomm_q(rcomm_q[i]), .addr_q(addr_q[i]), .addr_d(addr_d[i]), .way_q(way_q[i]),
      .size_q(size_q[i]), .master_q(master_q[i]), .master_d(master_d[i]), .id_q(id_q[i]), .rdata_q(rdata_q[i]),
      .vdirty_d(vdirty_d[i]), .vaddr_d(vaddr_d[i]), .vdata_d(vdata_d[i]),
      .rsv_mask(ent_rsv[i]), .vh_cur(vh_cur[i]), .vh_d(vh_d[i]), .vaddr_q(vaddr_q[i])
    );
  end

  // ---------------- request issue / response / refill views ----------------
  line_t e_rdata_w, e_vdata_w;
  ttg_onehot_mux #(.N(NMSHR), .W(512)) u_rdata (.sel(cs_oh), .data(rdata_q), .out(e_rdata_w));
  ttg_onehot_mux #(.N(NMSHR), .W(512)) u_vdata (.sel(cs_oh), .data(vdata_d), .out(e_vdata_w));
  assign e_rdata = e_rdata_w;
  assign e_vdata = e_vdata_w;

  always_comb begin
    resp_want = 1'b0;
    resp_master = '0;
    resp_eid = '0;
    e_bypass = 1'b0;
    e_rcomm = 1'b0;
    e_addr = '0;
    e_way = '0;
    e_master = '0;
    e_id = '0;
    e_vdirty = 1'b0;
    e_vaddr = '0;
    for (int i = 0; i < NMSHR; i++) begin
      resp_want |= resp_oh[i] && bypass_q[i];
      resp_master |= master_q[i] & {2{resp_oh[i]}};
      resp_eid |= id_q[i] & {4{resp_oh[i]}};
      e_bypass |= cs_oh[i] && bypass_q[i];
      e_rcomm |= cs_oh[i] && rcomm_q[i];
      e_addr |= addr_q[i] & {32{cs_oh[i]}};
      e_way |= way_q[i] & {WB{cs_oh[i]}};
      e_master |= master_q[i] & {2{cs_oh[i]}};
      e_id |= id_q[i] & {4{cs_oh[i]}};
      e_vdirty |= cs_oh[i] && vdirty_d[i];
      e_vaddr |= vaddr_d[i] & {32{cs_oh[i]}};
    end
  end

  always_comb begin
    rsv_mask = '0;
    for (int i = 0; i < NMSHR; i++) rsv_mask |= ent_rsv[i];
  end

  // memory read request of the picked entry (line read for refills, byte address for bypass reads)
  always_comb begin
    mrd_id = {1'b0, iss_idx};
    mrd_addr = a_addr;
    mrd_size = a_size;
    if (iss_any_q) begin
      mrd_addr = '0;
      mrd_size = '0;
      for (int i = 0; i < NMSHR; i++) begin
        if (iss_oh_q[i]) begin
          mrd_addr = bypass_q[i] ? addr_q[i] : line_of(addr_q[i]);
          mrd_size = bypass_q[i] ? size_q[i] : 8'd63;
        end
      end
    end
  end

  // hazard lists and interconnect view
  always_comb begin
    free_any_d = !(&valid_d);
    for (int m = 0; m < NR; m++) begin
      has_master_d[m] = 1'b0;
      for (int i = 0; i < NMSHR; i++) has_master_d[m] |= valid_d[i] && master_d[i] == 2'(m);
    end
    for (int i = 0; i < NMSHR; i++) begin
      vh_addr_cur[i] = vaddr_q[i];
      vh_addr_d[i] = vaddr_d[i];
      ml_vld_cur[i] = valid_q[i] && !bypass_q[i];
      ml_line_cur[i] = line_of(addr_q[i]);
      ml_vld_d[i] = valid_d[i] && !bypass_d[i];
      ml_line_d[i] = line_of(addr_d[i]);
      hz_valid[i] = valid_q[i];
      hz_master[i] = master_q[i];
      hz_id[i] = id_q[i];
      hz_line[i] = bypass_q[i] ? addr_q[i] : line_of(addr_q[i]);
    end
  end
endmodule

`default_nettype wire
