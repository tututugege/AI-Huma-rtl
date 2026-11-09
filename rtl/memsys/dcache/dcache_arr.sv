`default_nettype none
// Ref: MemSubSystem/DcacheConfig.cpp  Dcache_Read/Dcache_Write; RealDcache.cpp stage1 bank grant
// DCache arrays as 16 banks (dcache_bank).  Requesters of the read ports: the NSLOT LSU slots (granted ones only)
// and the fill snapshot (victim-selection read of the line being filled).  The bank grant of dcache_s1 guarantees
// one requester per bank per tick, so each bank sees a single read address (the OR of the requesters mapped to
// it).  The writes of one tick (store words, PLRU touches, line fill) belong to the same grant round and are in
// distinct banks too, so no write ordering exists.
module dcache_arr
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // slot reads: tag/valid + one word per way + PLRU of the slot's set
  input  logic [NSLOT-1:0]     rd_en,
  input  logic [31:0]          rd_addr   [NSLOT],
  output logic [WAYS-1:0]      rd_valid  [NSLOT],
  output logic [WAYS-1:0]      rd_pf     [NSLOT],
  output logic [TAG_W-1:0]     rd_tag    [NSLOT][WAYS],
  output logic [31:0]          rd_data   [NSLOT][WAYS],
  // fill snapshot: whole set (4 ways) of the line being filled
  input  logic                 fs_en,
  input  logic [SET_W-1:0]     fs_set,
  output logic [WAYS-1:0]      fs_valid,
  output logic [WAYS-1:0]      fs_dirty,
  output logic [2:0]           fs_plru,
  output logic [TAG_W-1:0]     fs_tag    [WAYS],
  output logic [LINE_BITS-1:0] fs_line   [WAYS],
  // writes (all take effect at the end of the tick)
  input  logic [NLD-1:0]       pfc_en,                // clear the pf bit of the hit way (load slots)
  input  logic [1:0]           pfc_way   [NLD],
  input  logic [NST-1:0]       sw_en,
  input  logic [SET_W-1:0]     sw_set    [NST],
  input  logic [1:0]           sw_way    [NST],
  input  logic [WORD_W-1:0]    sw_word   [NST],
  input  logic [31:0]          sw_data   [NST],
  input  logic [3:0]           sw_strb   [NST],
  input  st2_t                 sw_l2     [NST],
  input  logic [NSLOT-1:0]     lu_en,                 // PLRU touch of a slot's set (hit way)
  input  logic [1:0]           lu_way    [NSLOT],
  input  logic                 fw_en,
  input  logic [SET_W-1:0]     fw_set,
  input  logic [1:0]           fw_way,                // resolved target way (existing tag match or victim)
  input  logic [TAG_W-1:0]     fw_tag,
  input  logic                 fw_dirty,
  input  logic                 fw_pf,
  input  logic [LINE_BITS-1:0] fw_data
);

  // ---- requester -> bank mapping ----
  logic [NSLOT:0]    req_en;
  logic [SET_W-1:0]  req_set [NSLOT+1];
  always_comb begin
    for (int k = 0; k < NSLOT; k++) begin
      req_en[k]  = rd_en[k];
      req_set[k] = rd_addr[k][OFF_W +: SET_W];
    end
    req_en[NSLOT]  = fs_en;
    req_set[NSLOT] = fs_set;
  end

  // ---- per-bank wires ----
  logic [WAYS-1:0]       b_valid [BANKS];
  logic [WAYS-1:0]       b_dirty [BANKS];
  logic [WAYS-1:0]       b_pf    [BANKS];
  logic [TAG_W-1:0]      b_tag   [BANKS][WAYS];
  logic [2:0]            b_plru  [BANKS];
  logic [LINE_BITS-1:0]  b_line  [BANKS][WAYS];

  for (genvar b = 0; b < BANKS; b++) begin : g_bank
    logic [ROW_W-1:0]  rd_row;
    logic              fw_en_b;
    logic [NLD-1:0]    pfc_en_b;
    logic [ROW_W-1:0]  pfc_row_b [NLD];
    logic [NST-1:0]    sw_en_b;
    logic [ROW_W-1:0]  sw_row_b [NST];
    logic [NSLOT:0]    pl_en_b;
    logic [ROW_W-1:0]  pl_row_b [NSLOT+1];
    logic [2:0]        pl_bits_b [NSLOT+1];

    always_comb begin
      rd_row = '0;
      for (int k = 0; k <= NSLOT; k++)
        if (req_en[k] && req_set[k][BANK_W-1:0] == BANK_W'(b)) rd_row = rd_row | req_set[k][SET_W-1:BANK_W];
      for (int k = 0; k < NLD; k++) begin
        pfc_en_b[k]  = pfc_en[k] && req_set[k][BANK_W-1:0] == BANK_W'(b);
        pfc_row_b[k] = req_set[k][SET_W-1:BANK_W];
      end
      fw_en_b = fw_en && fw_set[BANK_W-1:0] == BANK_W'(b);
      for (int p = 0; p < NST; p++) begin
        sw_en_b[p]  = sw_en[p] && sw_set[p][BANK_W-1:0] == BANK_W'(b);
        sw_row_b[p] = sw_set[p][SET_W-1:BANK_W];
      end
      // PLRU: slot touch (new bits from the slot's own read) ports 0..NSLOT-1, fill touch port NSLOT
      for (int k = 0; k < NSLOT; k++) begin
        pl_en_b[k]   = lu_en[k] && req_set[k][BANK_W-1:0] == BANK_W'(b);
        pl_row_b[k]  = req_set[k][SET_W-1:BANK_W];
        pl_bits_b[k] = plru_touch(b_plru[b], lu_way[k]);
      end
      pl_en_b[NSLOT]   = fw_en_b;
      pl_row_b[NSLOT]  = fw_set[SET_W-1:BANK_W];
      pl_bits_b[NSLOT] = plru_touch(b_plru[b], fw_way);
    end

    dcache_bank u_bank (
      .clk(clk), .rst_n(rst_n),
      .rd_row(rd_row), .rd_valid(b_valid[b]), .rd_dirty(b_dirty[b]), .rd_pf(b_pf[b]), .rd_tag(b_tag[b]),
      .rd_plru(b_plru[b]), .rd_line(b_line[b]),
      .fw_en(fw_en_b), .fw_row(fw_set[SET_W-1:BANK_W]), .fw_way(fw_way), .fw_tag(fw_tag),
      .fw_dirty(fw_dirty), .fw_pf(fw_pf), .fw_data(fw_data),
      .pfc_en(pfc_en_b), .pfc_row(pfc_row_b), .pfc_way(pfc_way),
      .sw_en(sw_en_b), .sw_row(sw_row_b), .sw_way(sw_way), .sw_word(sw_word), .sw_data(sw_data),
      .sw_strb(sw_strb), .sw_l2(sw_l2),
      .pl_en(pl_en_b), .pl_row(pl_row_b), .pl_bits(pl_bits_b)
    );
  end

  // ---- bank outputs -> requesters ----
  for (genvar k = 0; k < NSLOT; k++) begin : g_slot
    logic [BANK_W-1:0] bk;
    assign bk = rd_addr[k][OFF_W +: BANK_W];
    assign rd_valid[k] = b_valid[bk];
    assign rd_pf[k]    = b_pf[bk];
    for (genvar w = 0; w < WAYS; w++) begin : g_way
      assign rd_tag[k][w]  = b_tag[bk][w];
      assign rd_data[k][w] = line_word(b_line[bk][w], rd_addr[k][2 +: WORD_W]);
    end
  end

  logic [BANK_W-1:0] fbk;
  assign fbk      = fs_set[BANK_W-1:0];
  assign fs_valid = b_valid[fbk];
  assign fs_dirty = b_dirty[fbk];
  assign fs_plru  = b_plru[fbk];
  for (genvar w = 0; w < WAYS; w++) begin : g_fway
    assign fs_tag[w]  = b_tag[fbk][w];
    assign fs_line[w] = b_line[fbk][w];
  end

`ifndef SYNTHESIS
  // one requester per bank per tick (guaranteed by the bank grant); the read row would otherwise be an OR of two rows
  logic [BANKS-1:0] bank_busy_dbg [NSLOT+1];
  always_comb begin
    for (int k = 0; k <= NSLOT; k++) begin
      bank_busy_dbg[k] = '0;
      if (req_en[k]) bank_busy_dbg[k][req_set[k][BANK_W-1:0]] = 1'b1;
    end
  end
  for (genvar i = 0; i <= NSLOT; i++) begin : g_chk_i
    for (genvar j = i + 1; j <= NSLOT; j++) begin : g_chk_j
      assert property (@(posedge clk) disable iff (!rst_n) ((bank_busy_dbg[i] & bank_busy_dbg[j]) == '0));
    end
  end
`endif

endmodule
`default_nettype wire
