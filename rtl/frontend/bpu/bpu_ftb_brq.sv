// Ref: front-end/BPU/BPU_pipe.h  FTB_BRQ (v10: 16-entry native 1.00 br/cyc commit queue + 512-entry 2-bank 1R1W ftb_rec)
`default_nettype none

module bpu_ftb_brq import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // S3 ftb_rec write ports (port 0: Block A, port 1: paired Block B; always opposite LSB -> 2 even/odd 1R1W banks)
  input  logic                    rec_wr_en,
  input  logic [FTB_REC_W-1:0]    rec_wr_addr,
  input  ftb_rec_t                rec_wr_data,
  input  logic                    rec_wr_b_en,
  input  logic [FTB_REC_W-1:0]    rec_wr_b_addr,
  input  ftb_rec_t                rec_wr_b_data,
  // 8-lane commit stream
  input  logic [NCOMMIT-1:0]      upd_valid,
  input  logic [XLEN_BITS-1:0]    base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0]      actual_dir,
  input  logic [NCOMMIT-1:0]      upd_is_rvc,
  input  logic [2:0]              br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0]    target     [NCOMMIT],
  input  logic [NCOMMIT-1:0]      pred_dir,
  input  logic [NCOMMIT-1:0]      alt_pred,
  input  logic [PCPN_W-1:0]       pcpn       [NCOMMIT],
  input  logic [FTB_BLK_ID_W-1:0] blk_id     [NCOMMIT],
  // Single-branch decoded head output (pops every cycle cnt_q != 0 -> native 1.00 br/cyc!)
  output logic                    upd_en,
  output logic [XLEN_BITS-1:0]    upd_start,
  output fh_t                     upd_fh,
  output ex_fh_t                  upd_ex_fh,
  output sc_fh_t                  upd_sc_fh,
  output logic [7:0]              upd_imli,
  output logic                    upd_ah_v,
  output logic                    upd_ah_kind,
  output logic [XLEN_BITS-1:0]    upd_ah_key_base,
  output logic [XLEN_BITS-1:0]    upd_ah_a_base,
  output fh_t                     upd_ah_key_fh,
  output s2_pred_meta_t           upd_s2_meta,
  output ah_pred_meta_t           upd_ah_meta,
  output ftb_br_upd_t             upd_br,
  output logic [XLEN_BITS-1:0]    upd_pc,
  // Commit credits to compact ROB (never backpressures ROB)
  output logic [3:0]              commit_upd_free,
  output logic [3:0]              commit_tq_free
);

  localparam int PTR_W      = $clog2(FTB_BRQ_N);
  localparam int CNT_W      = $clog2(FTB_BRQ_N + 1);
  localparam int REC_BDEPTH = FTB_REC_N / 2;
  localparam int REC_BAW    = FTB_REC_W - 1;
  localparam int REC_BITS   = $bits(ftb_rec_t);

  typedef struct packed {
    logic [FTB_BLK_ID_W-1:0] blk_id;
    logic [XLEN_BITS-1:0]    pc;
    logic                    is_rvc;
    logic [2:0]              br_type;
    logic                    actual_dir;
    logic                    pred_dir;
    logic                    alt_pred;
    logic [PCPN_W-1:0]       pcpn;
    logic [XLEN_BITS-1:0]    target;
  } brq_ent_t;

  // ---- 16-entry circular branch queue ----
  brq_ent_t         brq_q [FTB_BRQ_N];
  brq_ent_t         brq_d [FTB_BRQ_N];
  logic [PTR_W-1:0] head_q, head_d;
  logic [CNT_W-1:0] cnt_q, cnt_d;

  // ---- 512-entry ftb_rec as 2 even/odd banks of 256 x strict sync 1R1W SRAM (pre-launched from brq_d[head_d]) ----
  logic                 bank_re    [2];
  logic [REC_BAW-1:0]   bank_ra    [2];
  logic [REC_BITS-1:0]  bank_rd    [2];
  logic                 bank_we    [2];
  logic [REC_BAW-1:0]   bank_wa    [2];
  logic [REC_BITS-1:0]  bank_wd    [2];
  logic [FTB_REC_W-1:0] next_rec_id;

  always_comb begin
    next_rec_id = brq_d[head_d].blk_id[FTB_REC_W-1:0];
    bank_re[0]  = (cnt_d != '0) && !next_rec_id[0];
    bank_re[1]  = (cnt_d != '0) &&  next_rec_id[0];
    bank_ra[0]  = next_rec_id[FTB_REC_W-1:1];
    bank_ra[1]  = next_rec_id[FTB_REC_W-1:1];

    bank_we[0]  = (rec_wr_en && !rec_wr_addr[0]) || (rec_wr_b_en && !rec_wr_b_addr[0]);
    bank_wa[0]  = (rec_wr_en && !rec_wr_addr[0]) ? rec_wr_addr[FTB_REC_W-1:1] : rec_wr_b_addr[FTB_REC_W-1:1];
    bank_wd[0]  = (rec_wr_en && !rec_wr_addr[0]) ? REC_BITS'(rec_wr_data)     : REC_BITS'(rec_wr_b_data);

    bank_we[1]  = (rec_wr_en &&  rec_wr_addr[0]) || (rec_wr_b_en &&  rec_wr_b_addr[0]);
    bank_wa[1]  = (rec_wr_en &&  rec_wr_addr[0]) ? rec_wr_addr[FTB_REC_W-1:1] : rec_wr_b_addr[FTB_REC_W-1:1];
    bank_wd[1]  = (rec_wr_en &&  rec_wr_addr[0]) ? REC_BITS'(rec_wr_data)     : REC_BITS'(rec_wr_b_data);
  end

  for (genvar bk = 0; bk < 2; bk++) begin : g_rec_bk
    ttg_sram_1r1w #(
      .DEPTH      (REC_BDEPTH),
      .WIDTH      (REC_BITS),
      .MASK_W     (1),
      .WRITE_FIRST(1'b1),
      .TAG        ("BPU_FTB_REC")
    ) u_rec (
      .clk  (clk),
      .re   (bank_re[bk]),
      .raddr(bank_ra[bk]),
      .rdata(bank_rd[bk]),
      .we   (bank_we[bk]),
      .waddr(bank_wa[bk]),
      .wdata(bank_wd[bk]),
      .wmask(1'b1)
    );
  end

  // ---- Head pop (always 1.00 br/cyc whenever non-empty) & ftb_rec decode ----
  logic     do_pop, carried, in_blk;
  brq_ent_t q_head;
  ftb_rec_t rc;

  always_comb begin
    do_pop         = (cnt_q != '0);
    q_head         = brq_q[head_q];
    rc             = q_head.blk_id[0] ? ftb_rec_t'(bank_rd[1]) : ftb_rec_t'(bank_rd[0]);

    carried        = (q_head.pc + XLEN_BITS'(SLOT_BYTES) == rc.base);
    in_blk         = carried || ((q_head.pc >= rc.base) && (q_head.pc < block_bnd(rc.base)));
    upd_en         = do_pop && rc.valid && (rc.id == q_head.blk_id) && in_blk;

    upd_start         = rc.base;
    upd_fh            = rc.fh;
    upd_ex_fh         = rc.ex_fh;
    upd_sc_fh         = rc.sc_fh;
    upd_imli          = rc.imli;
    upd_ah_v          = rc.ah_v;
    upd_ah_kind       = rc.ah_kind;
    upd_ah_key_base   = rc.ah_key_base;
    upd_ah_a_base     = rc.ah_a_base;
    upd_ah_key_fh     = rc.ah_key_fh;
    upd_s2_meta       = rc.s2_meta;
    upd_ah_meta       = rc.ah_meta;
    upd_pc            = q_head.pc;
    upd_br.offset     = carried ? 4'd0 : 4'((q_head.pc - rc.base) >> SLOT_SHIFT);
    upd_br.carried    = carried;
    upd_br.is_rvc     = q_head.is_rvc;
    upd_br.br_type    = q_head.br_type;
    upd_br.actual_dir = q_head.actual_dir;
    upd_br.pred_dir   = q_head.pred_dir;
    upd_br.alt_pred   = q_head.alt_pred;
    upd_br.pcpn       = q_head.pcpn;
    upd_br.target     = q_head.target;
  end

  // ---- 8-lane enqueue (after pop frees 1 slot) ----
  logic [PTR_W-1:0] wr_idx;
  logic [CNT_W-1:0] cur_cnt;
  brq_ent_t         enq_e;

  always_comb begin
    for (int k = 0; k < FTB_BRQ_N; k++) brq_d[k] = brq_q[k];
    head_d  = head_q + PTR_W'(do_pop);
    cur_cnt = cnt_q - CNT_W'(do_pop);
    wr_idx  = '0;
    enq_e   = '0;

    for (int i = 0; i < NCOMMIT; i++) begin
      if (upd_valid[i] && (br_type[i] != BR_NONCTL) && (cur_cnt < CNT_W'(FTB_BRQ_N))) begin
        wr_idx           = head_d + PTR_W'(cur_cnt);
        enq_e.blk_id     = blk_id[i];
        enq_e.pc         = base_pc[i];
        enq_e.is_rvc     = upd_is_rvc[i];
        enq_e.br_type    = br_type[i];
        enq_e.actual_dir = actual_dir[i];
        enq_e.pred_dir   = pred_dir[i];
        enq_e.alt_pred   = alt_pred[i];
        enq_e.pcpn       = pcpn[i];
        enq_e.target     = target[i];
        brq_d[wr_idx]    = enq_e;
        cur_cnt          = cur_cnt + CNT_W'(1);
      end
    end
    cnt_d = cur_cnt;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q <= '0;
      cnt_q  <= '0;
      for (int k = 0; k < FTB_BRQ_N; k++) brq_q[k] <= '0;
    end else begin
      head_q <= head_d;
      cnt_q  <= cnt_d;
      for (int k = 0; k < FTB_BRQ_N; k++) brq_q[k] <= brq_d[k];
    end
  end

`ifndef SYNTHESIS
  logic [FTB_REC_W-1:0] dbg_rec_id_q;
  always_ff @(posedge clk) begin
    if (!rst_n) dbg_rec_id_q <= '0;
    else if (cnt_d != '0) dbg_rec_id_q <= next_rec_id;
  end
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (do_pop && (dbg_rec_id_q != q_head.blk_id[FTB_REC_W-1:0]))
        $error("bpu_ftb_brq: u_rec pre-launch mismatch latched=%0h actual=%0h",
               dbg_rec_id_q, q_head.blk_id[FTB_REC_W-1:0]);
      if (rec_wr_en && rec_wr_b_en && (rec_wr_addr[0] == rec_wr_b_addr[0]))
        $error("bpu_ftb_brq: u_rec bank conflict wr_a=%0h wr_b=%0h", rec_wr_addr, rec_wr_b_addr);
    end
  end
`endif

  assign commit_upd_free = 4'd15;
  assign commit_tq_free  = 4'd15;

endmodule

`default_nettype wire
