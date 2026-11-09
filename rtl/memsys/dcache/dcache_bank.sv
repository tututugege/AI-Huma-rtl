`default_nettype none
// Ref: MemSubSystem/DcacheConfig.cpp  Dcache_Read/Dcache_Write/write_dcache_line
// One of the 16 DCache banks (bank = set & 15): 16 rows x 4 ways of tag/valid/dirty/data + 16 PLRU words.  One
// asynchronous read port (address = row); synchronous write ports: line fill (1), store word write (NST), PLRU
// (NSLOT+1).  The parent guarantees at most one requester per bank per tick (bank grant of dcache_s1), so the
// ports never collide.
module dcache_bank
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // read port (data of the state at the start of the tick)
  input  logic [ROW_W-1:0]     rd_row,
  output logic [WAYS-1:0]      rd_valid,
  output logic [WAYS-1:0]      rd_dirty,
  output logic [WAYS-1:0]      rd_pf,       // line brought in by the prefetcher and not used yet (EXP-009)
  output logic [TAG_W-1:0]    rd_tag   [WAYS],
  output logic [2:0]           rd_plru,
  output logic [LINE_BITS-1:0] rd_line  [WAYS],
  // line fill: valid=1, dirty=fw_dirty, tag, whole line (way already resolved by the parent)
  input  logic                 fw_en,
  input  logic [ROW_W-1:0]     fw_row,
  input  logic [1:0]           fw_way,
  input  logic [TAG_W-1:0]     fw_tag,
  input  logic                 fw_dirty,
  input  logic                 fw_pf,
  input  logic [LINE_BITS-1:0] fw_data,
  // first demand use of a prefetched line: clear its pf bit (one request per bank per tick)
  input  logic [NLD-1:0]       pfc_en,
  input  logic [ROW_W-1:0]     pfc_row  [NLD],
  input  logic [1:0]           pfc_way  [NLD],
  // store word write (sets dirty)
  input  logic [NST-1:0]       sw_en,
  input  logic [ROW_W-1:0]     sw_row   [NST],
  input  logic [1:0]           sw_way   [NST],
  input  logic [WORD_W-1:0]    sw_word  [NST],
  input  logic [31:0]          sw_data  [NST],
  input  logic [3:0]           sw_strb  [NST],
  input  st2_t                 sw_l2    [NST],     // second word of the same row (merged store): same bank, same way
  // PLRU word write (later ports win)
  input  logic [NSLOT:0]       pl_en,
  input  logic [ROW_W-1:0]     pl_row   [NSLOT+1],
  input  logic [2:0]           pl_bits  [NSLOT+1]
);

  logic [ROWS-1:0]     valid_q [WAYS];
  logic [ROWS-1:0]     dirty_q [WAYS];
  logic [ROWS-1:0]     pf_q    [WAYS];
  logic [2:0]          plru_q  [ROWS];
  logic [TAG_W-1:0]    tag_q   [WAYS][ROWS];
  logic [LINE_BITS-1:0] data_q [WAYS][ROWS];

  for (genvar w = 0; w < WAYS; w++) begin : g_rd
    assign rd_valid[w] = valid_q[w][rd_row];
    assign rd_dirty[w] = dirty_q[w][rd_row];
    assign rd_pf[w]    = pf_q[w][rd_row];
    assign rd_tag[w]   = tag_q[w][rd_row];
    assign rd_line[w]  = data_q[w][rd_row];
  end
  assign rd_plru = plru_q[rd_row];

  // control bits: reset to the C++ init() state (all invalid / clean / PLRU 0)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int w = 0; w < WAYS; w++) begin
        valid_q[w] <= '0;
        dirty_q[w] <= '0;
        pf_q[w]    <= '0;
      end
      for (int r = 0; r < ROWS; r++) plru_q[r] <= '0;
    end else begin
      for (int k = 0; k < NLD; k++) if (pfc_en[k]) pf_q[pfc_way[k]][pfc_row[k]] <= 1'b0;
      for (int p = 0; p < NST; p++) if (sw_en[p]) dirty_q[sw_way[p]][sw_row[p]] <= 1'b1;
      if (fw_en) begin
        valid_q[fw_way][fw_row] <= 1'b1;
        dirty_q[fw_way][fw_row] <= fw_dirty;
        pf_q[fw_way][fw_row]    <= fw_pf;
      end
      for (int k = 0; k <= NSLOT; k++) if (pl_en[k]) plru_q[pl_row[k]] <= pl_bits[k];
    end
  end

  // tag/data content is not reset: it is only observable through valid (set by the fill that writes it)
  always_ff @(posedge clk) begin
    for (int p = 0; p < NST; p++)
      for (int b = 0; b < 4; b++)
        if (sw_en[p] && sw_strb[p][b])
          data_q[sw_way[p]][sw_row[p]][(32'(sw_word[p]) << 5) + 32'(8 * b) +: 8] <= sw_data[p][8*b +: 8];
    for (int p = 0; p < NST; p++)
      for (int b = 0; b < 4; b++)
        if (sw_en[p] && sw_l2[p].strb[b])
          data_q[sw_way[p]][sw_row[p]][(32'(sw_l2[p].word) << 5) + 32'(8 * b) +: 8] <= sw_l2[p].data[8*b +: 8];
    if (fw_en) begin
      tag_q[fw_way][fw_row]  <= fw_tag;
      data_q[fw_way][fw_row] <= fw_data;
    end
  end

endmodule
`default_nettype wire
