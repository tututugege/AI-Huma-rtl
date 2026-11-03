`default_nettype none
// Ref: MemSubSystem/WriteBuffer.cpp  class WriteBuffer (comb_inputs_axi, comb_outputs_dcache, comb_inputs_dcache,
// comb_outputs_axi, seq)
// 8-entry ring of evicted dirty lines (head = oldest, count, send flag while a write is outstanding).
// Tick order (merged from the C++ in-place `nxt` updates):
//   A: AXI accept sets send, the B response pops the head and clears send (a response wins over a same-tick accept);
// free = 8 - count; load bypass (youngest same-line entry, data before this tick's merges); store merge into the
// youngest same-line
//      entry (busy when it is the head and a write is outstanding), ports in order, later wins.
// B: the evicted line from stage 2 is appended at head+count; the AXI write request is the head when no write is
// outstanding
//      (its data already contains this tick's merges / append).
module dcache_wb
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 ax_req_accepted,
  input  logic                 ax_resp_valid,
  // load bypass lookups (granted load slots)
  input  logic [NLD-1:0]       byp_en,
  input  logic [LINE_W-1:0]    byp_line  [NLD],
  input  logic [WORD_W-1:0]    byp_word  [NLD],
  // store merge (granted store slots)
  input  logic [NST-1:0]       mrg_en,
  input  logic [LINE_W-1:0]    mrg_line  [NST],
  input  logic [WORD_W-1:0]    mrg_word  [NST],
  input  logic [31:0]          mrg_data  [NST],
  input  logic [3:0]           mrg_strb  [NST],
  // evicted dirty line from stage 2
  input  logic                 push_valid,
  input  logic [LINE_W-1:0]    push_line,
  input  logic [LINE_BITS-1:0] push_data,
  output logic [CNT_W-1:0]     free,
  output logic [NLD-1:0]       byp_hit,
  output logic [31:0]          byp_data  [NLD],
  output logic [NST-1:0]       mrg_ok,
  output logic [NST-1:0]       mrg_busy,
  // AXI write master outputs (after the whole tick; write response ready is constant 1)
  output logic                 ax_req_valid,
  output logic [LINE_W-1:0]    ax_req_line,
  output logic [LINE_BITS-1:0] ax_req_data
);

  logic [LINE_W-1:0]    line_q [WB_N];
  logic [LINE_BITS-1:0] data_q [WB_N];
  logic [CNT_W-1:0]     count_q;
  logic [WB_IDW-1:0]    head_q;
  logic                 send_q;

  // ---- A: AXI ----
  logic              pop, send_a;
  logic [CNT_W-1:0]  count_a;
  logic [WB_IDW-1:0] head_a;
  always_comb begin
    pop     = ax_resp_valid && count_q != '0;
    send_a  = ax_resp_valid ? 1'b0 : (ax_req_accepted ? 1'b1 : send_q);
    count_a = count_q - CNT_W'(pop);
    head_a  = head_q + WB_IDW'(pop);
  end
  assign free = CNT_W'(WB_N) - count_a;

  // ---- A: lookups ----
  logic [WB_IDW-1:0] byp_idx [NLD];
  logic [NLD-1:0]    byp_found;
  logic [WB_IDW-1:0] mrg_idx [NST];
  logic [NST-1:0]    mrg_found;
  for (genvar i = 0; i < NLD; i++) begin : g_byp
    dcache_wb_find u_find (.ent_line(line_q), .head(head_a), .count(count_a), .line(byp_line[i]),
                           .hit(byp_found[i]), .idx(byp_idx[i]));
    assign byp_hit[i]  = byp_en[i] && byp_found[i];
    assign byp_data[i] = line_word(data_q[byp_idx[i]], byp_word[i]);
  end
  for (genvar i = 0; i < NST; i++) begin : g_mrg
    dcache_wb_find u_find (.ent_line(line_q), .head(head_a), .count(count_a), .line(mrg_line[i]),
                           .hit(mrg_found[i]), .idx(mrg_idx[i]));
    assign mrg_busy[i] = mrg_en[i] && mrg_found[i] && mrg_idx[i] == head_a && send_a;
    assign mrg_ok[i]   = mrg_en[i] && mrg_found[i] && !mrg_busy[i];
  end

  // ---- B: append, AXI request ----
  logic              push_ok;
  logic [WB_IDW-1:0] tail;
  assign push_ok = push_valid && count_a < CNT_W'(WB_N);
  assign tail    = head_a + WB_IDW'(count_a);

  logic [CNT_W-1:0] count_b;
  assign count_b = count_a + CNT_W'(push_ok);

  // head entry as seen by the AXI request: merges of this tick that hit the head, or the freshly appended line
  // (empty buffer)
  logic [LINE_BITS-1:0] head_data;
  logic [LINE_W-1:0]    head_line;
  always_comb begin
    head_data = data_q[head_a];
    head_line = line_q[head_a];
    for (int p = 0; p < NST; p++)
      if (mrg_ok[p] && mrg_idx[p] == head_a) head_data = line_merge(head_data, mrg_word[p], mrg_data[p], mrg_strb[p]);
    if (push_ok && tail == head_a) begin
      head_data = push_data;
      head_line = push_line;
    end
  end
  assign ax_req_valid = !send_a && count_b != '0;
  assign ax_req_line  = head_line;
  assign ax_req_data  = head_data;

  // ---- registers ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count_q <= '0;
      head_q  <= '0;
      send_q  <= 1'b0;
    end else begin
      count_q <= count_b;
      head_q  <= head_a;
      send_q  <= send_a;
    end
  end

  // entry storage (no reset: entries are only read inside [head, head+count))
  always_ff @(posedge clk) begin
    for (int p = 0; p < NST; p++)
      for (int b = 0; b < 4; b++)
        if (mrg_ok[p] && mrg_strb[p][b])
          data_q[mrg_idx[p]][(32'(mrg_word[p]) << 5) + 32'(8 * b) +: 8] <= mrg_data[p][8*b +: 8];
    if (push_ok) begin
      line_q[tail] <= push_line;
      data_q[tail] <= push_data;
    end
  end

endmodule
`default_nettype wire
