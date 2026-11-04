`default_nettype none
// Ref: AXI_LLC.cpp  write_req_q / write_ctx / write_resp of one write master (drive_write_path, accept path)
// One write-master unit: request queue (WQD entries, a request passes straight through an empty queue) ->
// write context (one outstanding write: lookup launch, hit/miss resolution, optional victim write-back) ->
// write response register.  The context walks  FILL -> LPEND (waiting for the lookup engine) -> lookup ->
// [CPEND (waiting for the victim write-back or for the refill of a partial-line write miss)] -> CDONE (table
// updated) -> response.  A bypass (peripheral) write context instead completes when the memory write response
// arrives (MEM_ISSUED -> MEM_DONE); its lookup only updates a cached copy of the line.
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
  input  logic enq_bypass,
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
  output logic launch_bypass,
  output addr_t launch_addr,
  output logic [7:0] launch_size,
  output logic [3:0] launch_id,
  // lookup resolution (stage 3) results for this context
  input  logic s3_cdone,
  input  logic s3_cpend,
  input  logic s3_vwait,                       // the pending write waits for a victim write-back (else for a refill)
  input  logic wr_done,                        // refill of a partial-line write miss written into the table
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
  output logic cpend_q,                        // waiting for a victim write-back or a refill
  output logic vwait_q,                        // ... for a victim write-back (victim line is pending)
  output logic vwait_s2,                       // after this tick's victim write-back response
  output logic vwait_d,
  output addr_t vaddr_cur,
  output addr_t vaddr_d,                       // victim line of the pending write at the end of the tick
  output addr_t ctx_line,
  output logic [WQD:0] wl_vld_d,               // write-pending lines (queue entries + context), end of tick
  output logic [WQD:0][31:0] wl_line_d,
  // registers read by the interconnect / the response outputs
  // bypass write: memory write channel
  input  logic bp_issue,                       // the memory write request of this context is accepted
  input  logic bp_resp,                        // the memory write response belongs to this context
  input  logic [1:0] bp_code,
  output logic bp_cand,                        // waiting to be issued to memory
  output logic bp_owner,                       // issued, response outstanding
  output addr_t ctx_addr,
  output logic [3:0] ctx_id,
  output logic [1:0] resp_code_q,                // written at the response, valid with resp_valid_q
  output logic ctx_valid_q,
  output logic resp_valid_q,
  output logic [3:0] resp_id_q,
  output addr_t resp_line_q
);
  localparam int QW = $clog2(WQD);

  typedef struct packed {
    logic bypass;
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
    enq_ent = {enq_bypass, enq_id, enq_size, enq_addr, enq_data, enq_strb};
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

  // context flags.  resp_do clears the whole context; a late lookup result (cdone) may still hit a cleared or
  // refilled context, as in the C++ (the fill resets the flags first).
  logic vwait_n, bypass_q, mem_issued_q, mem_done_q, mem_done_d, byp_n;
  logic [1:0] rcode_d, rcode_q;

  always_comb begin
    mem_done_d = mem_done_q || bp_resp;
    byp_n = fill_do ? head_ent.bypass : bypass_q;
    resp_do = ctx_valid_q && !resp_s2 && (bypass_q ? mem_done_d : (cdone_q || commit));
    ctx_valid_d = fill_do || (ctx_valid_q && !resp_do);
    lpend_d = !resp_do && (lpend_q || fill_do) && !launch;
    cdone_d = !resp_do && ((cdone_q && !fill_do) || s3_cdone || commit || wr_done);
    cpend_n = !resp_do && ((cpend_q && !commit && !wr_done) || s3_cpend);
    vwait_n = !resp_do && ((vwait_q && !commit) || (s3_cpend && s3_vwait));
    resp_valid_d = resp_s2 || resp_do;
    rcode_d = bypass_q ? (bp_resp ? bp_code : rcode_q) : 2'd0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ctx_valid_q <= 1'b0;
      lpend_q <= 1'b0;
      cdone_q <= 1'b0;
      cpend_q <= 1'b0;
      vwait_q <= 1'b0;
      bypass_q <= 1'b0;
      mem_issued_q <= 1'b0;
      mem_done_q <= 1'b0;
      resp_valid_q <= 1'b0;
    end else begin
      ctx_valid_q <= ctx_valid_d;
      lpend_q <= lpend_d;
      cdone_q <= cdone_d;
      cpend_q <= cpend_n;
      vwait_q <= vwait_n;
      bypass_q <= byp_n && !resp_do;
      mem_issued_q <= !resp_do && !fill_do && (mem_issued_q || bp_issue);
      mem_done_q <= !resp_do && !fill_do && mem_done_d;
      resp_valid_q <= resp_valid_d;
    end
  end

  // context payload (written when the queue front moves in) and pending-write fields
  always_ff @(posedge clk) begin
    if (fill_do) begin
      ctx_id_q <= head_ent.id;
      ctx_size_q <= head_ent.size;
      ctx_addr_q <= head_ent.addr;
      ctx_data_q <= head_ent.data;
    end
    if (fill_do) ctx_strb_q <= head_ent.strb;
    else if (resp_do) ctx_strb_q <= '0;           // the cleared context merges nothing into a late lookup
    if (s3_cpend) begin
      way_q <= s3_way;
      vaddr_r_q <= s3_vaddr;
      line_r_q <= s3_line;
    end
    rcode_q <= rcode_d;
    if (resp_do) begin
      resp_id_q <= ctx_id_q;
      resp_line_q <= line_of(ctx_addr_q);
      resp_code_q <= rcode_d;
    end
  end

  // way reserved by a write waiting for its victim write-back / refill (old state only)
  always_comb begin
    rsv_mask = '0;
    if (cpend_q && set_of(ctx_addr_q) == rsv_set && line_of(ctx_addr_q) != rsv_line) rsv_mask[way_q] = 1'b1;
  end

  // outputs that only depend on registers
  always_comb begin
    commit_addr = ctx_addr_q;
    commit_way = way_q;
    commit_line = line_r_q;
    // the context as stage 3 and 4 see it: already cleared by this tick's response, or refilled by this tick's fill
    ctx_data = fill_do ? head_ent.data : ctx_data_q;
    ctx_strb = resp_do ? 64'd0 : (fill_do ? head_ent.strb : ctx_strb_q);
    ctx_size = resp_do ? 8'd0 : (fill_do ? head_ent.size : ctx_size_q);
    ctx_addr = ctx_addr_q;
    ctx_id = ctx_id_q;
    vwait_s2 = vwait_q && !commit;
    vaddr_cur = vaddr_r_q;
    ctx_line = line_of(ctx_addr_q);
    bp_cand = ctx_valid_q && bypass_q && !mem_done_q && !mem_issued_q;
    bp_owner = ctx_valid_q && bypass_q && mem_issued_q && !mem_done_q;
  end

  // lookup launch (depends on the queue front)
  always_comb begin
    launch_cand = (lpend_q && !resp_do) || fill_do;
    launch_addr = fill_do ? head_ent.addr : ctx_addr_q;
    launch_size = fill_do ? head_ent.size : ctx_size_q;
    launch_id = fill_do ? head_ent.id : ctx_id_q;
    launch_bypass = fill_do ? head_ent.bypass : bypass_q;
  end

  // end-of-tick view for the hazard checks (depends on the stage-3 results)
  always_comb begin
    vwait_d = vwait_n;
    vaddr_d = s3_cpend ? s3_vaddr : vaddr_r_q;
    for (int i = 0; i < WQD; i++) begin
      wl_vld_d[i] = vld_d[i];
      wl_line_d[i] = line_of((push_en && tail_q == QW'(i)) ? enq_addr : ent_q[i].addr);
    end
    wl_vld_d[WQD] = ctx_valid_d && !(byp_n ? (mem_done_d && !fill_do) : cdone_d);
    wl_line_d[WQD] = line_of(fill_do ? head_ent.addr : ctx_addr_q);
  end
endmodule

`default_nettype wire
