// Ref: front-end/front_top.cpp  FetchAddrPort, InstPort::comb_write, FrontControl::finish (pend_pair)
`default_nettype none

// Fetch-side buffers: fetch_addr_fifo (address + FetchPair), pending-pair tracker, and compact raw-halfword
// instruction_FIFO (Block A + optional Block B raw halfwords; single RVC expand + predecode runs after S2 A/B mux).
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
  output logic [5:0]       ic_next_fa_idx,
  output logic [5:0]       ic_next_b_idx,
  input  logic             b_hit,
  input  logic [4:0]       b_actual_n,
  input  logic [31:0]      b_fetch_group [FETCH_WIDTH],
  // instruction queue read side
  input  logic             inst_rd_en,
  output logic             inst_empty,
  output inst_fifo_entry_t inst_rd
);

  // ---- fetch_addr_fifo + in-flight FetchPair tracker ----
  fetch_pair_t fa_rd_pair, fa_next_pair;
  logic [XLEN_BITS-1:0] fa_next_addr;
  logic        pend_valid_q;
  logic [XLEN_BITS-1:0] pend_addr_q;
  fetch_pair_t pend_pair_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size_unused;
  logic unused_fa_next;
  assign unused_fa_next = ^{fa_next_addr, fa_next_pair};
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
    .next_rd_address  (fa_next_addr),
    .next_rd_pair     (fa_next_pair),
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
    // Next-cycle VIPT set indices for strict 1-cycle synchronous L1I Data SRAM pre-launch
    ic_next_fa_idx = fa_next_addr[11:6];
    ic_next_b_idx  = pend_nv ? pend_np.addr2[11:6] : fa_next_pair.addr2[11:6];
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
    if (fa_rd_valid && (fa_rd_address == ic_fetch_pc))     pr = fa_rd_pair;
    else if (pend_valid_q && (pend_addr_q == ic_fetch_pc)) pr = pend_pair_q;
    else                                                   pr = '0;
    want_pair    = ic_read_complete && !global_refetch &&
                   pr.valid && (pr.a_len != 4'd0) &&
                   !ic_page_fault_inst[0] && !ic_fetch_single_word && ic_inst_valid[pr.a_len - 4'd1];
    b_req_valid  = want_pair;
    b_req_addr   = pr.addr2;
    b_req_nwords = pr.b_len;
  end

  // ---- Pack compact raw-halfword instruction_FIFO entry (zero duplicate expand/predecode) ----
  logic [FETCH_WIDTH-1:0] a_inv_oh, a_last_oh;
  logic                   a_any_inv;
  logic [15:0]            a_hi16 [FETCH_WIDTH];
  logic [15:0]            a_up16, b_up16;

  ttg_first_set #(.N(FETCH_WIDTH)) u_a_inv (.req(~ic_inst_valid), .onehot(a_inv_oh), .any(a_any_inv));
  assign a_last_oh = a_any_inv ? {1'b0, a_inv_oh[FETCH_WIDTH-1:1]} : {1'b1, {(FETCH_WIDTH-1){1'b0}}};

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_hi
    assign a_hi16[i] = ic_fetch_group[i][31:16];
  end
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_a_up16 (.sel(a_last_oh), .data(a_hi16), .out(a_up16));

  always_comb begin
    b_up16 = 16'd0;
    if (b_hit && (b_actual_n != 5'd0))
      b_up16 = b_fetch_group[b_actual_n[3:0] - 4'd1][31:16];
  end

  inst_fifo_entry_t inst_wr_entry;
  logic             inst_wr_en;
  assign inst_wr_en = ic_read_complete && !global_refetch;

  always_comb begin
    inst_wr_entry               = '0;
    inst_wr_entry.is_pair       = want_pair;
    inst_wr_entry.a_len         = pr.a_len;
    inst_wr_entry.base_a        = ic_fetch_pc;
    inst_wr_entry.base_b        = pr.addr2;
    inst_wr_entry.valid_a       = ic_inst_valid;
    inst_wr_entry.pf_a          = ic_page_fault_inst;
    inst_wr_entry.single_word_a = ic_fetch_single_word;
    inst_wr_entry.up16_a        = a_up16;
    inst_wr_entry.b_ok          = want_pair && b_hit;
    inst_wr_entry.b_actual_n    = (want_pair && b_hit) ? b_actual_n : 5'd0;
    inst_wr_entry.up16_b        = b_up16;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      inst_wr_entry.raw_a[i] = ic_fetch_group[i][15:0];
      inst_wr_entry.raw_b[i] = b_fetch_group[i][15:0];
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic inst_full, inst_rd_valid;
  logic unused_hi;
  always_comb begin
    unused_hi = a_inv_oh[0];
    for (int i = 0; i < FETCH_WIDTH; i++) unused_hi ^= ^b_fetch_group[i][31:16];
  end
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
