`default_nettype none
// Ref: MemSubSystem/MemSubsystem.cpp  AxiLlcTableRuntime (data/meta/valid/repl tables, lookup_latency = 3); repl = SRRIP state
// Hardware memories: synchronous 1R1W SRAMs (ttg_sram_1r1w with WRITE_FIRST=1). Read index advances through
// p1_q -> p2_q, launching the synchronous SRAM read at tick t+2 so outputs arrive at tick t+3 (lookup_latency = 3),
// matching the original semantics where writes of tick t+2 are visible to a read requested in tick t.
module axi_llc_tables
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic rd_req,
  input  logic [SB-1:0] rd_set,
  input  tw_t tw,
  output logic lk_ok,
  output logic [WAYS-1:0] lk_v,
  output logic [WAYS-1:0] lk_d,
  output logic [WAYS-1:0] lk_pf,
  output logic [WAYS-1:0][TAGW-1:0] lk_t,
  output logic [WAYS-1:0][511:0] lk_line,
  output logic [RB-1:0] lk_repl
);
  // read index pipeline: p1 <- request (end of tick t), p2 launches sync SRAM read -> outputs valid at tick t+3
  logic [2:0]    pv_q;
  logic [SB-1:0] p1_q, p2_q;

  always_ff @(posedge clk) begin
    if (!rst_n) pv_q <= '0;
    else        pv_q <= {pv_q[1:0], rd_req};
    p1_q <= rd_set;
    p2_q <= p1_q;
  end

  wire [WAYS-1:0] way_mask = WAYS'(1) << tw.way;

  // Data & tag SRAM banks: one 1R1W SRAM per way
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    wire way_we = tw.line_en && (tw.way == WB'(w));

    ttg_sram_1r1w #(
      .DEPTH      (SETS),
      .WIDTH      (512),
      .MASK_W     (1),
      .WRITE_FIRST(1'b1),
      .TAG        ("LLC_DATA")
    ) u_data_sram (
      .clk  (clk), .rst_n(rst_n),
      .re   (pv_q[1]),
      .raddr(p2_q),
      .rdata(lk_line[w]),
      .we   (way_we),
      .waddr(tw.set),
      .wdata(tw.data),
      .wmask(1'b1)
    );

    ttg_sram_1r1w #(
      .DEPTH      (SETS),
      .WIDTH      (TAGW),
      .MASK_W     (1),
      .WRITE_FIRST(1'b1),
      .TAG        ("LLC_TAG")
    ) u_tag_sram (
      .clk  (clk), .rst_n(rst_n),
      .re   (pv_q[1]),
      .raddr(p2_q),
      .rdata(lk_t[w]),
      .we   (way_we),
      .waddr(tw.set),
      .wdata(tw.tag),
      .wmask(1'b1)
    );
  end

  // Per-set metadata SRAMs (valid / dirty / pf with per-way bit mask, plus SRRIP repl)
  ttg_sram_1r1w #(
    .DEPTH      (SETS),
    .WIDTH      (WAYS),
    .MASK_W     (WAYS),
    .WRITE_FIRST(1'b1),
    .TAG        ("LLC_VALID")
  ) u_valid_sram (
    .clk  (clk), .rst_n(rst_n),
    .re   (pv_q[1]),
    .raddr(p2_q),
    .rdata(lk_v),
    .we   (tw.line_en),
    .waddr(tw.set),
    .wdata({WAYS{1'b1}}),
    .wmask(way_mask)
  );

  ttg_sram_1r1w #(
    .DEPTH      (SETS),
    .WIDTH      (WAYS),
    .MASK_W     (WAYS),
    .WRITE_FIRST(1'b1),
    .TAG        ("LLC_DIRTY")
  ) u_dirty_sram (
    .clk  (clk), .rst_n(rst_n),
    .re   (pv_q[1]),
    .raddr(p2_q),
    .rdata(lk_d),
    .we   (tw.line_en),
    .waddr(tw.set),
    .wdata({WAYS{tw.dirty}}),
    .wmask(way_mask)
  );

  ttg_sram_1r1w #(
    .DEPTH      (SETS),
    .WIDTH      (WAYS),
    .MASK_W     (WAYS),
    .WRITE_FIRST(1'b1),
    .TAG        ("LLC_PF")
  ) u_pf_sram (
    .clk  (clk), .rst_n(rst_n),
    .re   (pv_q[1]),
    .raddr(p2_q),
    .rdata(lk_pf),
    .we   (tw.line_en || tw.pf_clr),
    .waddr(tw.set),
    .wdata({WAYS{tw.line_en ? tw.pf : 1'b0}}),
    .wmask(way_mask)
  );

  ttg_sram_1r1w #(
    .DEPTH      (SETS),
    .WIDTH      (RB),
    .MASK_W     (1),
    .WRITE_FIRST(1'b1),
    .TAG        ("LLC_REPL")
  ) u_repl_sram (
    .clk  (clk), .rst_n(rst_n),
    .re   (pv_q[1]),
    .raddr(p2_q),
    .rdata(lk_repl),
    .we   (tw.repl_en),
    .waddr(tw.set),
    .wdata(tw.repl),
    .wmask(1'b1)
  );

  assign lk_ok = pv_q[2];
endmodule

`default_nettype wire
