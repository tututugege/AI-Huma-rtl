// Ref: front-end/front_top.cpp  FrontControl::enables, InstPort::comb_write (2-stage F0->F1 ICache)
`default_nettype none

// Fetch-side buffers: Unified FTQ-64 ifu_ptr reader, in-flight accounting, inst_fifo push & Block B merge.
module front_fetch_buf import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   global_refetch,
  // Unified FTQ-64 registered view + S0/IFU handshake
  input  logic [XLEN_BITS-1:0]   ftq_ifu_addr,
  input  logic                   fa_rd_en,
  output logic                   fa_rd_valid,
  output logic [XLEN_BITS-1:0]   fa_rd_address,
  output logic                   inst_fifo_room,
  // icache F1 response (Block A + pre-read Lo/Hi Block B)
  input  logic [1:0]             ic_inflight,
  input  logic                   ic_read_complete,
  input  logic [XLEN_BITS-1:0]   ic_fetch_pc,
  input  logic [FETCH_WIDTH-1:0] ic_inst_valid,
  input  logic [FETCH_WIDTH-1:0] ic_page_fault_inst,
  input  logic [31:0]            ic_fetch_group [FETCH_WIDTH],
  input  logic                   ic_fetch_single_word,
  input  logic                   ic_b_is_pair,
  input  logic                   ic_b_is_tail,
  input  logic [3:0]             ic_b_a_len,
  input  logic                   b_hit,
  input  logic [4:0]             b_actual_n,
  input  logic [31:0]            b_fetch_group [FETCH_WIDTH],
  // instruction queue read side
  input  logic                   inst_rd_en,
  output logic                   inst_empty,
  output inst_fifo_entry_t       inst_rd
);

  logic [$clog2(INST_FIFO_DEPTH + 1)-1:0] inst_size;
  logic                                   inst_full;

  assign fa_rd_valid    = fa_rd_en;
  assign fa_rd_address  = ftq_ifu_addr;
  assign inst_fifo_room = (inst_size + {3'd0, ic_inflight}) < 5'(INST_FIFO_DEPTH);

  logic want_pair, want_tail;
  always_comb begin
    want_pair = ic_read_complete && !global_refetch && !inst_full && ic_b_is_pair &&
                !ic_page_fault_inst[0] && !ic_fetch_single_word;
    want_tail = ic_read_complete && !global_refetch && !inst_full && ic_b_is_tail &&
                !ic_page_fault_inst[0] && !ic_fetch_single_word;
  end

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
    inst_wr_entry.a_len         = want_pair ? ic_b_a_len : 4'd0;
    inst_wr_entry.base_a        = ic_fetch_pc;
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

  logic unused_hi;
  assign unused_hi = a_inv_oh[0];   // a_last_oh uses a_inv_oh[FETCH_WIDTH-1:1] only

  inst_fifo u_inst_fifo (
    .clk, .rst_n,
    .refetch  (global_refetch),
    .rd_en    (inst_rd_en),
    .wr_en    (inst_wr_en),
    .wr_entry (inst_wr_entry),
    .rd_entry (inst_rd),
    .full     (inst_full),
    .empty    (inst_empty),
    .size     (inst_size)
  );

endmodule

`default_nettype wire
