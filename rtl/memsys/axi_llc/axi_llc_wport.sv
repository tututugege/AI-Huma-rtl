`default_nettype none
// Ref: AXI_LLC.cpp  write_req_q / write_ctx / write_resp of one write master (drive_write_path, accept path)
// One write-master unit: request queue (WQD entries, a request passes straight through an empty queue) ->
// write context (one outstanding write: lookup launch, hit/miss resolution, optional victim write-back) ->
// write response register.  The context walks  FILL -> LPEND (waiting for the lookup engine) -> lookup ->
// [CPEND (waiting for the victim write-back)] -> CDONE (table updated) -> response.
module axi_llc_wport
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic resp_ready,                     // up_wr_resp_ready
  // request accepted into the queue this tick (from the write arbiter)
  input  logic enq,
  input  logic [3:0] enq_id,
  input  logic [7:0] enq_size,
  input  addr_t enq_addr,
  input  line_t enq_data,
  input  logic [63:0] enq_strb,
  output logic wq_free,                        // queue can take a request
  // queue front -> context
  input  logic fill_en,                        // the write path is not blocked by a victim write-back
  input  logic fill_blocked,                   // the front line is a victim being written back
  output addr_t head_addr,
  // victim write-back finished: table write of the merged line
  input  logic commit,
  output addr_t commit_addr,
  output logic [WB-1:0] commit_way,
  output line_t commit_line,
  // lookup launch
  input  logic launch,
  output logic launch_cand,
  output addr_t launch_addr,
  output logic [7:0] launch_size,
  output logic [3:0] launch_id,
  // lookup resolution (stage 3) results for this context
  input  logic s3_cdone,
  input  logic s3_cpend,
  input  addr_t s3_vaddr,
  input  logic [WB-1:0] s3_way,
  input  line_t s3_line,
  output line_t ctx_data,
  output logic [63:0] ctx_strb,
  output logic [7:0] ctx_size,
  // way reservation query (old state) and victim / write-pending lists
  input  logic [SB-1:0] rsv_set,
  input  addr_t rsv_line,
  output logic [WAYS-1:0] rsv_mask,
  output logic cpend_q,
  output logic cpend_s2,                       // after this tick's victim write-back response
  output logic cpend_d,
  output addr_t vaddr_cur,
  output addr_t ctx_line,
  output logic [WQD:0] wl_vld_d,               // write-pending lines (queue entries + context), end of tick
  output logic [WQD:0][31:0] wl_line_d,
  // registers read by the interconnect / the response outputs
  output logic ctx_valid_q,
  output logic resp_valid_q,
  output logic [3:0] resp_id_q,
  output addr_t resp_line_q
);
  localparam int QW = $clog2(WQD);

  typedef struct packed {
    logic [3:0] id;
    logic [7:0] size;
    addr_t addr;
    line_t data;
    logic [63:0] strb;
  } wq_ent_t;

  // ---------------- request queue (valid bits + pointers, storage written at the tail) ----------------
  logic [WQD-1:0] vld_q, vld_d;
  logic [QW-1:0] head_q, tail_q;
  wq_ent_t ent_q [WQD];
  wq_ent_t enq_ent, head_ent;
  logic q_empty, push_en, pop_en;

  // ---------------- write context ----------------
  logic lpend_q, lpend_d, cdone_q, cdone_d, cpend_n, ctx_valid_d;
  logic [3:0] ctx_id_q;
  logic [7:0] ctx_size_q;
  addr_t ctx_addr_q;
  line_t ctx_data_q;
  logic [63:0] ctx_strb_q;
  logic [WB-1:0] way_q;
  addr_t vaddr_r_q;
  line_t line_r_q;
  logic fill_do, resp_s2, resp_do, resp_valid_d;

  always_comb begin
    enq_ent = {enq_id, enq_size, enq_addr, enq_data, enq_strb};
    q_empty = !(|vld_q);
    wq_free = !(&vld_q);
    head_ent = q_empty ? enq_ent : ent_q[head_q];
    head_addr = head_ent.addr;
    resp_s2 = resp_valid_q && !resp_ready;
    fill_do = fill_en && !ctx_valid_q && !resp_s2 && (!q_empty || enq) && !fill_blocked;
    pop_en = fill_do && !q_empty;
    push_en = enq && !(fill_do && q_empty);
    for (int i = 0; i < WQD; i++) begin
      vld_d[i] = (vld_q[i] && !(pop_en && head_q == QW'(i))) || (push_en && tail_q == QW'(i));
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vld_q <= '0;
      head_q <= '0;
      tail_q <= '0;
    end else begin
      vld_q <= vld_d;
      head_q <= head_q + QW'(pop_en);
      tail_q <= tail_q + QW'(push_en);
    end
  end
  for (genvar i = 0; i < WQD; i++) begin : g_ent
    always_ff @(posedge clk) begin
      if (push_en && tail_q == QW'(i)) ent_q[i] <= enq_ent;
    end
  end

  // context flags
  always_comb begin
    resp_do = ctx_valid_q && !resp_s2 && (cdone_q || commit);
    ctx_valid_d = fill_do || (ctx_valid_q && !resp_do);
    lpend_d = (lpend_q || fill_do) && !launch;
    cdone_d = !resp_do && (cdone_q || s3_cdone || commit);
    cpend_n = (cpend_q && !commit) || s3_cpend;
    resp_valid_d = resp_s2 || resp_do;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ctx_valid_q <= 1'b0;
      lpend_q <= 1'b0;
      cdone_q <= 1'b0;
      cpend_q <= 1'b0;
      resp_valid_q <= 1'b0;
    end else begin
      ctx_valid_q <= ctx_valid_d;
      lpend_q <= lpend_d;
      cdone_q <= cdone_d;
      cpend_q <= cpend_n;
      resp_valid_q <= resp_valid_d;
    end
  end

  // context payload (written when the queue front moves in) and victim-pending fields
  always_ff @(posedge clk) begin
    if (fill_do) begin
      ctx_id_q <= head_ent.id;
      ctx_size_q <= head_ent.size;
      ctx_addr_q <= head_ent.addr;
      ctx_data_q <= head_ent.data;
      ctx_strb_q <= head_ent.strb;
    end
    if (s3_cpend) begin
      way_q <= s3_way;
      vaddr_r_q <= s3_vaddr;
      line_r_q <= s3_line;
    end
    if (resp_do) begin
      resp_id_q <= ctx_id_q;
      resp_line_q <= line_of(ctx_addr_q);
    end
  end

  // way reserved by a write waiting for its victim write-back (old state only)
  always_comb begin
    rsv_mask = '0;
    if (cpend_q && set_of(ctx_addr_q) == rsv_set && line_of(ctx_addr_q) != rsv_line) rsv_mask[way_q] = 1'b1;
  end

  // outputs that only depend on registers
  always_comb begin
    commit_addr = ctx_addr_q;
    commit_way = way_q;
    commit_line = line_r_q;
    ctx_data = ctx_data_q;
    ctx_strb = ctx_strb_q;
    ctx_size = ctx_size_q;
    cpend_s2 = cpend_q && !commit;
    vaddr_cur = vaddr_r_q;
    ctx_line = line_of(ctx_addr_q);
  end

  // lookup launch (depends on the queue front)
  always_comb begin
    launch_cand = lpend_q || fill_do;
    launch_addr = fill_do ? head_ent.addr : ctx_addr_q;
    launch_size = fill_do ? head_ent.size : ctx_size_q;
    launch_id = fill_do ? head_ent.id : ctx_id_q;
  end

  // end-of-tick view for the hazard checks (depends on the stage-3 results)
  always_comb begin
    cpend_d = cpend_n;
    for (int i = 0; i < WQD; i++) begin
      wl_vld_d[i] = vld_d[i];
      wl_line_d[i] = line_of((push_en && tail_q == QW'(i)) ? enq_addr : ent_q[i].addr);
    end
    wl_vld_d[WQD] = ctx_valid_d && !cdone_d;
    wl_line_d[WQD] = line_of(fill_do ? head_ent.addr : ctx_addr_q);
  end
endmodule

`default_nettype wire
