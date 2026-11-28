// Ref: front-end/front_top.cpp  FrontControl::enables, InstPort::comb_write (2-stage F0->F1 ICache),
// InstPort::comb_read (line-straddle raw A/B merge)
`default_nettype none

// Fetch-side buffers: Unified FTQ-64 ifu_ptr reader, in-flight accounting, Block A / Block B merge, inst_fifo push.
// The merge of a same-page line straddle (Block A's first a_len slots, then Block B = the next line from halfword 0)
// is done here, before the queue, so each entry holds one halfword window (inst_fifo_entry_t).
module front_fetch_buf import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   global_refetch,
  // Unified FTQ-64 registered view + S0/IFU handshake
  input  logic [XLEN_BITS-1:0]   ftq_ifu_addr,
  input  logic                   ifu_rd_en,
  output logic                   ifu_rd_valid,
  output logic [XLEN_BITS-1:0]   ifu_rd_address,
  output logic                   inst_fifo_room,
  // icache F1 response (Block A + pre-read Lo Block B)
  input  logic [1:0]             ic_inflight,
  input  logic                   ic_read_complete,
  input  logic [XLEN_BITS-1:0]   ic_fetch_pc,
  input  logic [FETCH_WIDTH-1:0] ic_inst_valid,
  input  logic [FETCH_WIDTH-1:0] ic_page_fault_inst,
  input  logic [15:0]            ic_fetch_half [FETCH_WIDTH],
  input  logic [15:0]            ic_fetch_up16,
  input  logic                   ic_fetch_single_word,
  input  logic                   ic_b_is_straddle,
  input  logic                   ic_b_is_tail,
  input  logic [3:0]             ic_b_a_len,
  input  logic                   b_hit,
  input  logic [3:0]             b_actual_n,
  input  logic [15:0]            b_half [FETCH_WIDTH],
  // instruction queue read side
  input  logic                   inst_rd_en,
  output logic                   inst_empty,
  output inst_fifo_entry_t       inst_rd
);

  localparam logic [15:0] INST_NOP_LO = 16'h0013;

  logic [$clog2(INST_FIFO_DEPTH + 1)-1:0] inst_size;
  logic                                   inst_full;

  assign ifu_rd_valid   = ifu_rd_en;
  assign ifu_rd_address = ftq_ifu_addr;
  assign inst_fifo_room = (inst_size + {3'd0, ic_inflight}) < 5'(INST_FIFO_DEPTH);

  logic inst_wr_en, want_straddle, want_tail, b_ok;
  always_comb begin
    inst_wr_en    = ic_read_complete && !global_refetch && !inst_full;
    want_straddle = inst_wr_en && ic_b_is_straddle && !ic_page_fault_inst[0] && !ic_fetch_single_word;
    want_tail     = inst_wr_en && ic_b_is_tail && !ic_page_fault_inst[0] && !ic_fetch_single_word;
    b_ok          = b_hit && (b_actual_n != 4'd0);
  end

  // ---- A/B merge: slots [0, a_len) from Block A, slots [a_len, a_len + b_n) from Block B ----
  logic [FETCH_WIDTH-1:0] m_v, m_pf;
  logic [15:0]            m_half [FETCH_WIDTH];
  logic [15:0]            a_up16;   // halfword above Block A's last valid slot (tail: B's first halfword)

  always_comb begin
    a_up16 = (want_tail && b_ok) ? b_half[0] : ic_fetch_up16;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      logic [3:0] j;
      j = 4'(i) - ic_b_a_len;
      if (want_straddle && (4'(i) >= ic_b_a_len)) begin
        m_v[i]    = b_hit && (j < b_actual_n);
        m_pf[i]   = 1'b0;
        m_half[i] = m_v[i] ? b_half[j] : INST_NOP_LO;
      end else begin
        m_v[i]    = ic_inst_valid[i];
        m_pf[i]   = ic_page_fault_inst[i];
        m_half[i] = ic_fetch_half[i];
      end
    end
  end

  // Halfword above the last valid slot.  A straddle with B ends inside B: the halfword above B's last slot
  // (icache: a_len + b_n = 16).  Otherwise the last slot is an A slot: the next A slot if it is on (a straddle
  // whose B missed and whose a_len cuts A short), else the halfword above A.  A faulting group has 0.
  logic [FETCH_WIDTH-1:0] m_inv_oh, m_last_oh;
  logic                   m_any_inv;
  logic [15:0]            a_next [FETCH_WIDTH];
  logic [15:0]            a_last_up16, b_up16;

  ttg_first_set #(.N(FETCH_WIDTH)) u_m_inv (.req(~m_v), .onehot(m_inv_oh), .any(m_any_inv));
  assign m_last_oh = m_any_inv ? {1'b0, m_inv_oh[FETCH_WIDTH-1:1]} : {1'b1, {(FETCH_WIDTH-1){1'b0}}};
  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_next
    if (i + 1 < FETCH_WIDTH) begin : g_mid
      assign a_next[i] = ic_page_fault_inst[i] ? 16'h0 : (ic_inst_valid[i + 1] ? ic_fetch_half[i + 1] : a_up16);
    end else begin : g_end
      assign a_next[i] = ic_page_fault_inst[i] ? 16'h0 : a_up16;
    end
  end
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_a_last_up16 (.sel(m_last_oh), .data(a_next), .out(a_last_up16));
  assign b_up16 = b_half[b_actual_n];   // b_actual_n <= 15 (a_len >= 1)

  inst_fifo_entry_t inst_wr_entry;
  always_comb begin
    inst_wr_entry             = '0;
    inst_wr_entry.is_straddle = want_straddle;
    inst_wr_entry.single_word = ic_fetch_single_word;
    inst_wr_entry.tail_ok     = want_tail && b_ok;
    inst_wr_entry.base        = ic_fetch_pc;
    inst_wr_entry.valid       = m_v;
    inst_wr_entry.pf          = m_pf;
    inst_wr_entry.up16        = (want_straddle && b_ok) ? b_up16 : a_last_up16;
    for (int i = 0; i < FETCH_WIDTH; i++) inst_wr_entry.half[i] = m_half[i];
  end

  logic unused_fb;
  assign unused_fb = m_inv_oh[0];   // m_last_oh uses m_inv_oh[FETCH_WIDTH-1:1] only

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

`ifndef SYNTHESIS
  // the up16 of a straddle with B assumes B ends the window: a_len + b_n <= FETCH_WIDTH (icache: = 16)
  always_comb if (want_straddle && b_ok) assert (5'(ic_b_a_len) + 5'(b_actual_n) <= 5'(FETCH_WIDTH));
`endif

endmodule

`default_nettype wire
