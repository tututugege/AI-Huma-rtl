// Cleanup F equivalence (item 4): front_ctrl with front_refetch_ctrl / front_ctrl_enables folded in against the old
// wiring wrapper (ref/), random inputs every cycle for NCYC cycles, every output compared every cycle.
`default_nettype none
module eq_ctrl import ttg_cfg_pkg::*; #(parameter int NCYC = 1000000) ();
  logic clk = 1'b0, rst_n = 1'b0;
  longint unsigned rs = 64'h0123456789abcdef;
  function automatic longint unsigned rnd();
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
  endfunction

  logic                 be_refetch, be_rd, ic_ready, ftq_full, ifu_empty, inst_empty, room, s2_empty, rv, s2req, chk_fl;
  logic [1:0]           cnt_sat, hold_n, sq_n;
  logic [XLEN_BITS-1:0] be_addr, chk_addr;
  logic [XLEN_BITS-1:0] o_ra, n_ra;
  logic [1:0]           o_dt, n_dt;
  logic                 o_gr, o_ifu, o_pcr, o_rr, o_s0, o_s2, o_fl, n_gr, n_ifu, n_pcr, n_rr, n_s0, n_s2, n_fl;

  front_ctrl_ref u_o (.clk, .rst_n, .be_refetch, .be_refetch_address(be_addr), .be_fifo_read_enable(be_rd),
    .icache_ready(ic_ready), .ftq_full, .ifu_empty, .ifu_cnt_sat(cnt_sat), .bpu_hold_n(hold_n), .inst_empty,
    .inst_fifo_room(room), .s2_empty, .bpu_icache_read_valid(rv), .bpu_s2_wr_req(s2req), .checker_flush_enable(chk_fl),
    .bpu_override_squash_n(sq_n), .checker_flush_address(chk_addr), .global_refetch(o_gr), .refetch_address(o_ra),
    .ifu_rd_en(o_ifu), .predecode_can_run(o_pcr), .bpu_icache_read_ready(o_rr), .s0_wr_en(o_s0),
    .s0_drop_tail_n(o_dt), .s2_wr_en(o_s2), .do_predecode_flush(o_fl));
  front_ctrl u_n (.clk, .rst_n, .be_refetch, .be_refetch_address(be_addr), .be_fifo_read_enable(be_rd),
    .icache_ready(ic_ready), .ftq_full, .ifu_empty, .ifu_cnt_sat(cnt_sat), .bpu_hold_n(hold_n), .inst_empty,
    .inst_fifo_room(room), .s2_empty, .bpu_icache_read_valid(rv), .bpu_s2_wr_req(s2req), .checker_flush_enable(chk_fl),
    .bpu_override_squash_n(sq_n), .checker_flush_address(chk_addr), .global_refetch(n_gr), .refetch_address(n_ra),
    .ifu_rd_en(n_ifu), .predecode_can_run(n_pcr), .bpu_icache_read_ready(n_rr), .s0_wr_en(n_s0),
    .s0_drop_tail_n(n_dt), .s2_wr_en(n_s2), .do_predecode_flush(n_fl));

  int ncyc = 0, nerr = 0, nfl = 0;
  task automatic drive();
    longint unsigned r = rnd();
    be_refetch = (r % 16) == 0;
    {be_rd, ic_ready, ftq_full, ifu_empty, inst_empty, room, s2_empty, rv, s2req, chk_fl} = 10'(r >> 8);
    {cnt_sat, hold_n, sq_n} = 6'(r >> 20);
    be_addr  = rnd();
    chk_addr = rnd();
  endtask
  always @(posedge clk) if (rst_n) begin
    ncyc++;
    nfl += o_fl;
    if ({o_gr, o_ra, o_ifu, o_pcr, o_rr, o_s0, o_dt, o_s2, o_fl} !== {n_gr, n_ra, n_ifu, n_pcr, n_rr, n_s0, n_dt, n_s2, n_fl}) begin
      nerr++;
      if (nerr <= 10) $display("cycle %0d: old %h %h %b%b%b%b %h %b%b / new %h %h %b%b%b%b %h %b%b", ncyc,
        o_gr, o_ra, o_ifu, o_pcr, o_rr, o_s0, o_dt, o_s2, o_fl, n_gr, n_ra, n_ifu, n_pcr, n_rr, n_s0, n_dt, n_s2, n_fl);
    end
  end
  initial begin
    drive();
    repeat (3) begin #1 clk = 1'b1; #1 clk = 1'b0; end
    rst_n = 1'b1;
    for (int c = 0; c < NCYC; c++) begin drive(); #1 clk = 1'b1; #1 clk = 1'b0; end
    if (nerr == 0) $display("PASS eq_ctrl: %0d cycles (%0d predecode flushes), 0 mismatches", ncyc, nfl);
    else           $display("FAIL eq_ctrl: %0d mismatches", nerr);
    $finish;
  end
endmodule
`default_nettype wire
