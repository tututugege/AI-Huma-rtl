// Ref: front-end/BPU/BPU_pipe.h  FTB_BRQ (16-entry BRQ + single-bank u_rec + T0->T1 training register)
`default_nettype none

module bpu_ftb_brq import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // S2 ftb_rec single write port
  input  logic                    rec_wr_en,
  input  logic [FTB_REC_W-1:0]    rec_wr_addr,
  input  ftb_rec_t                rec_wr_data,
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
  // 2-cycle registered head output (T0 -> T1: decoupled from the u_rec read)
  output logic                    upd_en,
  output logic [XLEN_BITS-1:0]    upd_start,
  output ex_fh_t                  upd_ex_fh,
  output logic                    upd_ah_v,
  output logic                    upd_ah_self0,
  output logic [XLEN_BITS-1:0]    upd_ah_key_base,
  output logic [XLEN_BITS-1:0]    upd_prev_base,
  output ex_fh0_t                 upd_ah_key_ex_fh,
  output ftb1_lookup_meta_t       upd_ftb1_meta,
  output ah_pred_meta_t           upd_ah_meta,
  output ftb_br_upd_t             upd_br,
  output logic [XLEN_BITS-1:0]    upd_pc,
  // Commit credits to compact ROB
  output logic [3:0]              commit_upd_free,
  output logic [3:0]              commit_tq_free
);

  localparam int PTR_W    = $clog2(FTB_BRQ_N);
  localparam int CNT_W    = $clog2(FTB_BRQ_N + 1);
  localparam int REC_BITS = $bits(ftb_rec_t);

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

  brq_ent_t         brq_q [FTB_BRQ_N];
  brq_ent_t         brq_d [FTB_BRQ_N];
  logic [PTR_W-1:0] head_q, head_d;
  logic [CNT_W-1:0] cnt_q, cnt_d;

  logic [FTB_REC_W-1:0] next_rec_id;
  logic [REC_BITS-1:0]  rec_rd_raw;

  assign next_rec_id = brq_d[head_d].blk_id[FTB_REC_W-1:0];

  ttg_sram_1r1w #(
    .DEPTH      (FTB_REC_N),
    .WIDTH      (REC_BITS),
    .MASK_W     (1),
    .TAG        ("BPU_FTB_REC")
  ) u_rec (
    .clk  (clk), .rst_n(rst_n),
    .re   (cnt_d != '0),
    .raddr(next_rec_id),
    .rdata(rec_rd_raw),
    .we   (rec_wr_en),
    .waddr(rec_wr_addr),
    .wdata(REC_BITS'(rec_wr_data)),
    .wmask(1'b1)
  );

  // ---- Stage T0 decode -> Stage T1 pipeline registers ----
  logic                 do_pop, carried, in_blk, t1_v_d;
  brq_ent_t             q_head;
  ftb_rec_t             rc;
  ftb_br_upd_t          t1_br_d;

  logic                 train_t1_v_q;
  /* verilator lint_off UNUSEDSIGNAL */
  ftb_rec_t             train_t1_rc_q;
  /* verilator lint_on UNUSEDSIGNAL */
  ftb_br_upd_t          train_t1_br_q;
  logic [XLEN_BITS-1:0] train_t1_pc_q;

  always_comb begin
    do_pop  = (cnt_q != '0);
    q_head  = brq_q[head_q];
    rc      = ftb_rec_t'(rec_rd_raw);
    carried = (q_head.pc + XLEN_BITS'(SLOT_BYTES) == rc.base);
    in_blk  = carried || ((q_head.pc >= rc.base) && (q_head.pc < block_bnd(rc.base)));
    t1_v_d  = do_pop && rc.valid && (rc.id == q_head.blk_id) && in_blk;

    t1_br_d.offset     = carried ? 4'd0 : 4'((q_head.pc - rc.base) >> SLOT_SHIFT);
    t1_br_d.carried    = carried;
    t1_br_d.is_rvc     = q_head.is_rvc;
    t1_br_d.br_type    = q_head.br_type;
    t1_br_d.actual_dir = q_head.actual_dir;
    t1_br_d.pred_dir   = q_head.pred_dir;
    t1_br_d.alt_pred   = q_head.alt_pred;
    t1_br_d.pcpn       = q_head.pcpn;
    t1_br_d.target     = q_head.target;
  end

  assign upd_en           = train_t1_v_q;
  assign upd_start        = train_t1_rc_q.base;
  assign upd_ex_fh        = train_t1_rc_q.ex_fh;
  assign upd_ah_v         = train_t1_rc_q.ah_v;
  assign upd_ah_self0     = train_t1_rc_q.ah_self0;
  assign upd_ah_key_base  = train_t1_rc_q.ah_key_base;
  assign upd_prev_base    = train_t1_rc_q.prev_base;
  assign upd_ah_key_ex_fh = train_t1_rc_q.ah_key_ex_fh;
  assign upd_ftb1_meta    = train_t1_rc_q.ftb1_meta;
  assign upd_ah_meta      = train_t1_rc_q.ah_meta;
  assign upd_br           = train_t1_br_q;
  assign upd_pc           = train_t1_pc_q;

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
      head_q        <= '0;
      cnt_q         <= '0;
      train_t1_v_q  <= 1'b0;
      train_t1_br_q <= '0;
      train_t1_pc_q <= '0;
      for (int k = 0; k < FTB_BRQ_N; k++) brq_q[k] <= '0;
    end else begin
      head_q       <= head_d;
      cnt_q        <= cnt_d;
      train_t1_v_q <= t1_v_d;
      for (int k = 0; k < FTB_BRQ_N; k++) brq_q[k] <= brq_d[k];
      if (t1_v_d) begin
        train_t1_br_q <= t1_br_d;
        train_t1_pc_q <= q_head.pc;
      end
    end
    if (!rst_n)      train_t1_rc_q <= '0;
    else if (t1_v_d) train_t1_rc_q <= rc;
  end

`ifndef SYNTHESIS
  logic [FTB_REC_W-1:0] dbg_rec_id_q;
  always_ff @(posedge clk) begin
    if (!rst_n)           dbg_rec_id_q <= '0;
    else if (cnt_d != '0) dbg_rec_id_q <= next_rec_id;
  end
  always_ff @(posedge clk) begin
    if (rst_n && do_pop && (dbg_rec_id_q != q_head.blk_id[FTB_REC_W-1:0]))
      $error("bpu_ftb_brq: u_rec pre-launch mismatch latched=%0h actual=%0h",
             dbg_rec_id_q, q_head.blk_id[FTB_REC_W-1:0]);
  end
`endif

  assign commit_upd_free = 4'd15;
  assign commit_tq_free  = 4'd15;

endmodule
`default_nettype wire
