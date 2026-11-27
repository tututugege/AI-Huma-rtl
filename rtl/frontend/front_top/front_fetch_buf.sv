// Ref: front-end/front_top.cpp  FrontControl::enables (ifu_ptr read), InstPort::comb_write, FrontControl::finish (pend_pair)
`default_nettype none

// Fetch-side buffers: Unified FTQ-64 ifu_ptr reader (replaces fetch_addr_fifo), pending-pair tracker,
// explicit inst_fifo backpressure, and compact raw-halfword instruction_FIFO.
module front_fetch_buf import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             global_refetch,
  input  logic             do_predecode_flush,
  // Unified FTQ-64 registered view + S0/IFU handshake
  input  logic             ftq_fa_empty,
  input  logic [1:0]       ftq_fa_cnt_sat,
  input  logic [XLEN_BITS-1:0] ftq_ifu_addr,
  input  fetch_pair_t      ftq_ifu_pair,
  input  logic [5:0]       ftq_ifu_next_fa_idx,
  input  logic [5:0]       ftq_ifu_next_b_idx,
  input  logic             fa_rd_en,
  input  logic [XLEN_BITS-1:0] fa_wr_address,
  input  fetch_pair_t      fa_wr_pair,
  output logic             fa_rd_valid,
  output logic [XLEN_BITS-1:0] fa_rd_address,
  output logic             inst_fifo_room,
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

  // ---- Unified FTQ-64 ifu_ptr head + in-flight request tracker (Same-Page Line-Straddle 2-Fetch) ----
  logic        pend_valid_q;
  logic [XLEN_BITS-1:0] pend_addr_q;
  logic [$clog2(INST_FIFO_DEPTH + 1)-1:0] inst_size;

  assign fa_rd_valid    = fa_rd_en;
  assign fa_rd_address  = ftq_ifu_addr;
  assign inst_fifo_room = (inst_size + 5'(pend_valid_q)) < 5'(INST_FIFO_DEPTH);

  // Ref: FrontControl::finish pend_valid / pend_addr
  logic ic_last_complete, head_done, pend_nv;
  logic [XLEN_BITS-1:0] pend_na;
  always_comb begin
    ic_last_complete = ic_read_complete && !do_predecode_flush;
    head_done        = ic_last_complete && fa_rd_valid && (fa_rd_address == ic_fetch_pc);
    pend_nv          = pend_valid_q;
    pend_na          = pend_addr_q;
    if (ic_last_complete && pend_nv && (pend_addr_q == ic_fetch_pc)) pend_nv = 1'b0;
    if (fa_rd_valid && !head_done) begin
      pend_nv = 1'b1;
      pend_na = fa_rd_address;
    end
    if (global_refetch) pend_nv = 1'b0;
    // Next-cycle VIPT set indices for strict 1-cycle synchronous L1I Data SRAM pre-launch
    // Bank B is always the next sequential 64B line (line + 1 -> guaranteed different bank, zero conflict!)
    ic_next_fa_idx = global_refetch ? fa_wr_address[11:6]
                   : fa_rd_valid    ? ((ftq_fa_cnt_sat == 2'd1) ? fa_wr_address[11:6] : ftq_ifu_next_fa_idx)
                   : ftq_fa_empty   ? fa_wr_address[11:6]
                                    : ftq_ifu_addr[11:6];
    ic_next_b_idx  = (pend_nv ? pend_na[11:6] : ic_next_fa_idx) + 6'd1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend_valid_q <= 1'b0;
      pend_addr_q  <= '0;
    end else begin
      pend_valid_q <= pend_nv;
      pend_addr_q  <= pend_na;
    end
  end

  // ---- Same-Page Line-Straddle 2-Fetch (pure function of ic_fetch_pc; zero pend_pair / zero 2nd ITLB port!) ----
  // Also handles off6 == 32 (line_idx != 63): reads 1st halfword of Line L+1 into up16_a so a 32-bit Taken branch
  // starting at off6 == 62 completes in the same cycle without a Predecode Flush!
  logic                 inst_full;
  logic                 same_page_next, straddle, tail_next, want_pair, want_tail;
  logic [3:0]           str_a_len, str_b_len;
  logic [XLEN_BITS-1:0] str_addr2;
  always_comb begin
    same_page_next = (ic_fetch_pc[11:6] != 6'h3f);
    straddle       = (ic_fetch_pc[5:0] > 6'd32) && same_page_next;
    tail_next      = (ic_fetch_pc[5:0] == 6'd32) && same_page_next;
    str_a_len      = straddle ? 4'((7'd64 - {1'b0, ic_fetch_pc[5:0]}) >> 1) : 4'd0;
    str_b_len      = straddle ? (4'd0 - str_a_len) : (tail_next ? 4'd1 : 4'd0);
    str_addr2      = {ic_fetch_pc[XLEN_BITS-1:6] + (XLEN_BITS-6)'(1), 6'd0};
    want_pair      = ic_read_complete && !global_refetch && !inst_full && straddle && (str_a_len != 4'd0) &&
                     !ic_page_fault_inst[0] && !ic_fetch_single_word && ic_inst_valid[str_a_len - 4'd1];
    want_tail      = ic_read_complete && !global_refetch && !inst_full && tail_next &&
                     !ic_page_fault_inst[0] && !ic_fetch_single_word && ic_inst_valid[FETCH_WIDTH - 1];
    b_req_valid    = want_pair || want_tail;
    b_req_addr     = str_addr2;
    b_req_nwords   = str_b_len;
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
  assign inst_wr_en = ic_read_complete && !global_refetch && !inst_full;

  always_comb begin
    inst_wr_entry               = '0;
    inst_wr_entry.is_pair       = want_pair;
    inst_wr_entry.a_len         = str_a_len;
    inst_wr_entry.base_a        = ic_fetch_pc;
    inst_wr_entry.base_b        = str_addr2;
    inst_wr_entry.valid_a       = ic_inst_valid;
    inst_wr_entry.pf_a          = ic_page_fault_inst;
    inst_wr_entry.single_word_a = ic_fetch_single_word;
    inst_wr_entry.up16_a        = (want_tail && b_hit && (b_actual_n != 5'd0)) ? b_fetch_group[0][15:0] : a_up16;
    inst_wr_entry.b_ok          = (want_pair || want_tail) && b_hit && (b_actual_n != 5'd0);
    inst_wr_entry.b_actual_n    = (want_pair && b_hit) ? b_actual_n : 5'd0;
    inst_wr_entry.up16_b        = b_up16;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      inst_wr_entry.raw_a[i] = ic_fetch_group[i][15:0];
      inst_wr_entry.raw_b[i] = b_fetch_group[i][15:0];
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic inst_rd_valid;
  logic unused_hi;
  always_comb begin
    unused_hi = a_inv_oh[0] ^ (^fa_wr_address) ^ (^fa_wr_pair) ^ (^ftq_ifu_pair) ^ (^ftq_ifu_next_b_idx);
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
    .empty    (inst_empty),
    .size     (inst_size)
  );

endmodule

`default_nettype wire
