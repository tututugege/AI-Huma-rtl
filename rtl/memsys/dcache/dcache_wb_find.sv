`default_nettype none
// Ref: MemSubSystem/WriteBuffer.cpp  find_wb_entry
// Youngest WriteBuffer entry (ring: head = oldest, count entries) holding a line: the C++ scans from head and keeps
// the LAST match.
module dcache_wb_find
  import dcache_pkg::*;
(
  input  logic [LINE_W-1:0]   ent_line [WB_N],
  input  logic [WB_IDW-1:0]   head,
  input  logic [CNT_W-1:0]    count,
  input  logic [LINE_W-1:0]   line,
  output logic                hit,
  output logic [WB_IDW-1:0]   idx
);

  // match vector in age order (bit j = entry head+j), then the highest set bit = youngest
  logic [WB_N-1:0] age_match, age_match_rev, young_rev_oh;
  logic            any_match;
  always_comb begin
    for (int j = 0; j < WB_N; j++) begin
      age_match[j] = CNT_W'(j) < count && ent_line[WB_IDW'(head + WB_IDW'(j))] == line;
      age_match_rev[WB_N-1-j] = age_match[j];
    end
  end
  ttg_first_set #(.N(WB_N)) u_young (.req(age_match_rev), .onehot(young_rev_oh), .any(any_match));
  always_comb begin
    hit = any_match;
    idx = '0;
    for (int j = 0; j < WB_N; j++) if (young_rev_oh[WB_N-1-j]) idx = WB_IDW'(head + WB_IDW'(j));
  end

endmodule
`default_nettype wire
