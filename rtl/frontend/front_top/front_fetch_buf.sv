// Ref: front-end/front_top.cpp  FetchAddrPort, InstPort::comb_write, FrontControl::finish (pend_pair)
`default_nettype none

// Fetch-side buffers: fetch_addr_fifo (address + FetchPair), pending-pair tracker, parallel Block B fusion +
// intact Block A fallback (S2-confirmed A/B mux), RVC expansion + predecode, and instruction_FIFO.
module front_fetch_buf import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             global_refetch,
  input  logic             do_predecode_flush,
  // fetch address queue
  input  logic             fa_rd_en,
  input  logic             fa_wr_en,
  input  logic             fa_drop_tail,
  input  logic [XLEN_BITS-1:0] fa_wr_address,
  input  fetch_pair_t      fa_wr_pair,
  output logic             fa_rd_valid,
  output logic [XLEN_BITS-1:0] fa_rd_address,
  output logic             fa_full,
  output logic             fa_empty,
  output logic             fa_head_fresh,
  // icache response (Block A + parallel Block B)
  input  logic             ic_read_complete,
  input  logic [XLEN_BITS-1:0] ic_fetch_pc,
  input  logic [FETCH_WIDTH-1:0] ic_inst_valid,
  input  logic [FETCH_WIDTH-1:0] ic_page_fault_inst,
  input  logic [31:0]      ic_fetch_group [FETCH_WIDTH],
  input  logic             ic_fetch_single_word,
  output logic             b_req_valid,
  output logic [XLEN_BITS-1:0] b_req_addr,
  output logic [3:0]       b_req_nwords,
  input  logic             b_hit,
  input  logic [4:0]       b_actual_n,
  input  logic [31:0]      b_fetch_group [FETCH_WIDTH],
  // instruction queue read side
  input  logic             inst_rd_en,
  output logic             inst_empty,
  output inst_fifo_entry_t inst_rd
);

  localparam logic [31:0] INST_NOP = 32'h00000013;

  // ---- fetch_addr_fifo + in-flight FetchPair tracker ----
  fetch_pair_t fa_rd_pair;
  logic        pend_valid_q;
  logic [XLEN_BITS-1:0] pend_addr_q;
  fetch_pair_t pend_pair_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  fetch_addr_fifo u_fa_fifo (
    .clk, .rst_n,
    .refetch          (global_refetch),
    .rd_en            (fa_rd_en),
    .wr_en            (fa_wr_en),
    .drop_tail        (fa_drop_tail),
    .wr_fetch_address (fa_wr_address),
    .wr_pair          (fa_wr_pair),
    .rd_valid         (fa_rd_valid),
    .rd_fetch_address (fa_rd_address),
    .rd_pair          (fa_rd_pair),
    .full             (fa_full),
    .empty            (fa_empty),
    .size             (fa_size_unused),
    .head_fresh       (fa_head_fresh)
  );

  // Ref: FrontControl::finish pend_valid / pend_addr / pend_pair
  logic ic_last_complete, head_done, pend_nv;
  logic [XLEN_BITS-1:0] pend_na;
  fetch_pair_t pend_np;
  always_comb begin
    ic_last_complete = ic_read_complete && !do_predecode_flush;
    head_done        = ic_last_complete && fa_rd_valid && (fa_rd_address == ic_fetch_pc);
    pend_nv          = pend_valid_q;
    pend_na          = pend_addr_q;
    pend_np          = pend_pair_q;
    if (ic_last_complete && pend_nv && (pend_addr_q == ic_fetch_pc)) pend_nv = 1'b0;
    if (fa_rd_valid && !head_done) begin
      pend_nv = 1'b1;
      pend_na = fa_rd_address;
      pend_np = fa_rd_pair;
    end
    if (global_refetch) pend_nv = 1'b0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend_valid_q <= 1'b0;
      pend_addr_q  <= '0;
      pend_pair_q  <= '0;
    end else begin
      pend_valid_q <= pend_nv;
      pend_addr_q  <= pend_na;
      pend_pair_q  <= pend_np;
    end
  end

  // ---- Pair selection & Block B request ----
  fetch_pair_t pr;
  logic        want_pair;
  always_comb begin
    if (fa_rd_valid && (fa_rd_address == ic_fetch_pc))       pr = fa_rd_pair;
    else if (pend_valid_q && (pend_addr_q == ic_fetch_pc))   pr = pend_pair_q;
    else                                                     pr = '0;
    want_pair    = ic_read_complete && !global_refetch &&
                   pr.valid && (pr.a_len != 4'd0) &&
                   !ic_page_fault_inst[0] && !ic_fetch_single_word && ic_inst_valid[pr.a_len - 4'd1];
    b_req_valid  = want_pair;
    b_req_addr   = pr.addr2;
    b_req_nwords = pr.b_len;
  end

  // ---- Intact Block A path (alt_a fallback) ----
  logic [31:0]           agrp_m [FETCH_WIDTH], a_ex_inst [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]  apc    [FETCH_WIDTH], a_ptgt    [FETCH_WIDTH];
  logic [1:0]            a_pty  [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] a_is_rvc, a_start_a, a_start_b;
  logic [15:0]           a_up16;
  logic                  a_up_ok;
  logic [XLEN_BITS-1:0]  a_seq_next;

  always_comb begin
    int anv;
    anv     = 0;
    a_up16  = 16'd0;
    a_up_ok = 1'b0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      apc[i]    = ic_fetch_pc + XLEN_BITS'(i * SLOT_BYTES);
      agrp_m[i] = ic_fetch_group[i];
      if ((anv == i) && ic_inst_valid[i]) anv = i + 1;
    end
    if ((RVC_ENABLE != 0) && (anv > 0)) begin
      a_up16           = ic_fetch_group[anv - 1][31:16];
      a_up_ok          = (((apc[anv - 1] + XLEN_BITS'(SLOT_BYTES)) & XLEN_BITS'(ICACHE_LINE_SIZE - 1)) != '0);
      agrp_m[anv - 1]  = {16'd0, ic_fetch_group[anv - 1][15:0]};
    end
  end

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_alt_rvc
    logic [31:0] ex;
    rvc_expand u_exp_a (.h(agrp_m[i][15:0]), .inst(ex));
    assign a_is_rvc[i]  = (RVC_ENABLE != 0) && ic_inst_valid[i] && (agrp_m[i][1:0] != 2'b11);
    assign a_ex_inst[i] = a_is_rvc[i] ? ex : agrp_m[i];
  end

  predecode u_predecode_a (
    .clk, .rst_n, .slot_pc(apc), .inst(a_ex_inst), .inst_valid(ic_inst_valid),
    .predecode_type(a_pty), .predecode_target_address(a_ptgt)
  );

  sequential_next_pc u_seq_next_pc (
    .clk, .rst_n, .fetch_pc(ic_fetch_pc), .inst_valid(ic_inst_valid), .seq_next_pc(a_seq_next)
  );

  always_comb begin
    logic prev_v;
    a_start_a = '0;
    a_start_b = '0;
    prev_v    = 1'b1;
    if (RVC_ENABLE != 0) begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        if (prev_v && ic_inst_valid[i]) begin
          a_start_a[i] = (i == 0) ? 1'b1 : (!a_start_a[i - 1] || a_is_rvc[i - 1]);
          a_start_b[i] = (i == 0) ? 1'b0 : (!a_start_b[i - 1] || a_is_rvc[i - 1]);
        end else begin
          prev_v = 1'b0;
        end
      end
    end
  end

  // ---- Main (fused A+B or single A) path ----
  logic [31:0]           grp    [FETCH_WIDTH], grp_m [FETCH_WIDTH], ex_inst [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]  gpc    [FETCH_WIDTH], ptgt  [FETCH_WIDTH];
  logic [1:0]            pty    [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] gv, gpf, is_rvc, start_a, start_b;
  logic [15:0]           rvc_up16;
  logic                  rvc_up_ok;
  logic [XLEN_BITS-1:0]  seq_next_pc;

  always_comb begin
    int nv;
    logic [3:0] j;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      j = 4'(i) - pr.a_len;
      if (want_pair && (4'(i) >= pr.a_len)) begin
        gpc[i] = pr.addr2 + (XLEN_BITS'(j) << SLOT_SHIFT);
        gv[i]  = b_hit && ({1'b0, j} < b_actual_n);
        gpf[i] = 1'b0;
        grp[i] = gv[i] ? b_fetch_group[j] : INST_NOP;
      end else begin
        gpc[i] = ic_fetch_pc + XLEN_BITS'(i * SLOT_BYTES);
        gv[i]  = ic_inst_valid[i];
        gpf[i] = ic_page_fault_inst[i];
        grp[i] = ic_fetch_group[i];
      end
      grp_m[i] = grp[i];
    end
    nv        = 0;
    rvc_up16  = 16'd0;
    rvc_up_ok = 1'b0;
    for (int i = 0; i < FETCH_WIDTH; i++) if ((nv == i) && gv[i]) nv = i + 1;
    if ((RVC_ENABLE != 0) && (nv > 0)) begin
      rvc_up16      = grp[nv - 1][31:16];
      rvc_up_ok     = !ic_fetch_single_word &&
                      (((gpc[nv - 1] + XLEN_BITS'(SLOT_BYTES)) & XLEN_BITS'(ICACHE_LINE_SIZE - 1)) != '0);
      grp_m[nv - 1] = {16'd0, grp[nv - 1][15:0]};
    end
    if (want_pair && (nv > 0)) seq_next_pc = gpc[nv - 1] + XLEN_BITS'(SLOT_BYTES);
    else                       seq_next_pc = a_seq_next;
  end

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_rvc
    logic [31:0] ex;
    rvc_expand u_expand (.h(grp_m[i][15:0]), .inst(ex));
    assign is_rvc[i]  = (RVC_ENABLE != 0) && gv[i] && (grp_m[i][1:0] != 2'b11);
    assign ex_inst[i] = is_rvc[i] ? ex : grp_m[i];
  end

  predecode u_predecode (
    .clk, .rst_n, .slot_pc(gpc), .inst(ex_inst), .inst_valid(gv),
    .predecode_type(pty), .predecode_target_address(ptgt)
  );

  always_comb begin
    logic prev_v, bnd;
    start_a = '0;
    start_b = '0;
    prev_v  = 1'b1;
    bnd     = 1'b0;
    if (RVC_ENABLE != 0) begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        bnd = (i > 0) && (gpc[i] != gpc[i - 1] + XLEN_BITS'(SLOT_BYTES));
        if (prev_v && gv[i]) begin
          start_a[i] = (i == 0) ? 1'b1 : (bnd || !start_a[i - 1] || is_rvc[i - 1]);
          start_b[i] = (i == 0) ? 1'b0 : (bnd || !start_b[i - 1] || is_rvc[i - 1]);
        end else begin
          prev_v = 1'b0;
        end
      end
    end
  end

  // ---- Pack instruction_FIFO entry ----
  inst_fifo_entry_t inst_wr_entry;
  logic             inst_wr_en;
  assign inst_wr_en = ic_read_complete && !global_refetch;

  always_comb begin
    inst_wr_entry             = '0;
    inst_wr_entry.is_pair     = want_pair;
    inst_wr_entry.a_len       = pr.a_len;
    inst_wr_entry.base_a      = ic_fetch_pc;
    inst_wr_entry.base_b      = pr.addr2;
    inst_wr_entry.up16        = rvc_up16;
    inst_wr_entry.up_ok       = rvc_up_ok;
    inst_wr_entry.raw0        = grp_m[0][15:0];
    inst_wr_entry.start_a     = start_a;
    inst_wr_entry.start_b     = start_b;
    inst_wr_entry.is_rvc      = is_rvc;
    inst_wr_entry.seq_next_pc = seq_next_pc;
    inst_wr_entry.inst_valid  = gv;
    inst_wr_entry.page_fault_inst = gpf;
    inst_wr_entry.has_alt_a   = want_pair;
    inst_wr_entry.alt_up16    = a_up16;
    inst_wr_entry.alt_up_ok   = a_up_ok;
    inst_wr_entry.alt_start_a = a_start_a;
    inst_wr_entry.alt_start_b = a_start_b;
    inst_wr_entry.alt_is_rvc  = a_is_rvc;
    inst_wr_entry.alt_seq_next_pc = a_seq_next;
    inst_wr_entry.alt_inst_valid  = ic_inst_valid;
    inst_wr_entry.alt_page_fault_inst = ic_page_fault_inst;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      inst_wr_entry.instructions[i]                 = ex_inst[i];
      inst_wr_entry.predecode_type[i]               = pty[i];
      inst_wr_entry.predecode_target_address[i]     = ptgt[i];
      inst_wr_entry.alt_instructions[i]             = a_ex_inst[i];
      inst_wr_entry.alt_predecode_type[i]           = a_pty[i];
      inst_wr_entry.alt_predecode_target_address[i] = a_ptgt[i];
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic inst_full, inst_rd_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  inst_fifo u_inst_fifo (
    .clk, .rst_n,
    .refetch  (global_refetch),
    .rd_en    (inst_rd_en),
    .wr_en    (inst_wr_en),
    .wr_entry (inst_wr_entry),
    .rd_valid (inst_rd_valid),
    .rd_entry (inst_rd),
    .full     (inst_full),
    .empty    (inst_empty)
  );

endmodule

`default_nettype wire
