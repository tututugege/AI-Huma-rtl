`default_nettype none
// Ref: MemSubSystem/DcacheConfig.cpp  Dcache_Read/Dcache_Write/write_dcache_line
// One of the 16 DCache banks (bank = set & 15): 16 rows x 4 ways of tag/valid/dirty/data + 16 PLRU words.
// Tag and data arrays use standalone synchronous 1R1W SRAMs (ttg_sram_1r1w with WRITE_FIRST=1), launched at the
// S1->S2 clock edge via (sram_re, sram_rrow) so outputs arrive in S2 with 0-cycle latency change.
module dcache_bank
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // synchronous SRAM read launch (from S1, arrives at next cycle S2)
  input  logic                 sram_re,
  input  logic [ROW_W-1:0]     sram_rrow,
  // control-bit read port (current S2 row)
  input  logic [ROW_W-1:0]     rd_row,
  output logic [WAYS-1:0]      rd_valid,
  output logic [WAYS-1:0]      rd_dirty,
  output logic [WAYS-1:0]      rd_pf,       // line brought in by the prefetcher and not used yet (EXP-009)
  output logic [TAG_W-1:0]     rd_tag   [WAYS],
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
  input  logic [DW-1:0]        sw_data  [NST],
  input  logic [SBW-1:0]       sw_strb  [NST],
  input  st2_t                 sw_l2    [NST],     // second word of the same row (merged store): same bank, same way
  // PLRU word write (later ports win)
  input  logic [NSLOT:0]       pl_en,
  input  logic [ROW_W-1:0]     pl_row   [NSLOT+1],
  input  logic [2:0]           pl_bits  [NSLOT+1]
);

  localparam int LINE_BYTES = LINE_BITS / 8;

  logic [ROWS-1:0] valid_q [WAYS];
  logic [ROWS-1:0] dirty_q [WAYS];
  logic [ROWS-1:0] pf_q    [WAYS];
  logic [2:0]      plru_q  [ROWS];

  for (genvar w = 0; w < WAYS; w++) begin : g_rd
    assign rd_valid[w] = valid_q[w][rd_row];
    assign rd_dirty[w] = dirty_q[w][rd_row];
    assign rd_pf[w]    = pf_q[w][rd_row];
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

  // Tag & Data synchronous 1R1W SRAMs (one pair per way; bank grant guarantees <= 1 writer per bank per tick)
  for (genvar w = 0; w < WAYS; w++) begin : g_sram
    logic                  tag_we, data_we;
    logic [ROW_W-1:0]      data_waddr;
    logic [LINE_BITS-1:0]  data_wdata;
    logic [LINE_BYTES-1:0] data_wmask;

    assign tag_we = fw_en && (fw_way == 2'(w));

    always_comb begin
      data_we    = 1'b0;
      data_waddr = '0;
      data_wdata = '0;
      data_wmask = '0;
      for (int p = 0; p < NST; p++) begin
        if (sw_en[p] && (sw_way[p] == 2'(w))) begin
          data_we    = 1'b1;
          data_waddr = sw_row[p];
          for (int b = 0; b < SBW; b++) begin
            if (sw_strb[p][b]) begin
              data_wdata[(32'(sw_word[p]) * DW) + 32'(8 * b) +: 8] = sw_data[p][8 * b +: 8];
              data_wmask[(32'(sw_word[p]) * SBW) + 32'(b)]         = 1'b1;
            end
          end
          for (int b = 0; b < SBW; b++) begin
            if (sw_l2[p].strb[b]) begin
              data_wdata[(32'(sw_l2[p].word) * DW) + 32'(8 * b) +: 8] = sw_l2[p].data[8 * b +: 8];
              data_wmask[(32'(sw_l2[p].word) * SBW) + 32'(b)]         = 1'b1;
            end
          end
        end
      end
      if (fw_en && (fw_way == 2'(w))) begin
        data_we    = 1'b1;
        data_waddr = fw_row;
        data_wdata = fw_data;
        data_wmask = {LINE_BYTES{1'b1}};
      end
    end

    ttg_sram_1r1w #(
      .DEPTH      (ROWS),
      .WIDTH      (TAG_W),
      .MASK_W     (1),
      .WRITE_FIRST(1'b1),
      .TAG        ("DCACHE_TAG")
    ) u_tag_sram (
      .clk  (clk), .rst_n(rst_n),
      .re   (sram_re),
      .raddr(sram_rrow),
      .rdata(rd_tag[w]),
      .we   (tag_we),
      .waddr(fw_row),
      .wdata(fw_tag),
      .wmask(1'b1)
    );

    ttg_sram_1r1w #(
      .DEPTH      (ROWS),
      .WIDTH      (LINE_BITS),
      .MASK_W     (LINE_BYTES),
      .WRITE_FIRST(1'b1),
      .TAG        ("DCACHE_DATA")
    ) u_data_sram (
      .clk  (clk), .rst_n(rst_n),
      .re   (sram_re),
      .raddr(sram_rrow),
      .rdata(rd_line[w]),
      .we   (data_we),
      .waddr(data_waddr),
      .wdata(data_wdata),
      .wmask(data_wmask)
    );
  end

endmodule
`default_nettype wire
