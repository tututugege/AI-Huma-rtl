`default_nettype none
// Ref: MemSubSystem/include/BingoHw.h (EXP-058)
// 1RW SRAM PHT_L (256x4x138b) + PHT_S (128x4x133b) with 3b tree-PLRU & 3-state FSM (ST_IDLE/ST_PRED/ST_CMT).
module axi_llc_bingo_pht
  import axi_llc_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        pred_pend_v,
  input  logic [19:0] pred_pend_reg,
  input  logic [17:0] pred_pend_key,
  input  logic [11:0] pred_pend_pch,
  input  logic [5:0]  pred_pend_off,
  input  logic        cmt_empty,
  input  logic [17:0] cmt_head_key,
  input  logic [5:0]  cmt_head_off,
  input  logic [63:0] cmt_head_mask,
  output logic        pred_consume,
  output logic        cmt_pop,
  output logic        pred_out_v,
  output logic [19:0] pred_out_reg,
  output logic [5:0]  pred_out_off,
  output logic [63:0] pred_out_mask
);
  localparam int PHTL_SETS  = BINGO_PHTL_SETS;
  localparam int PHTS_SETS  = BINGO_PHTS_SETS;
  localparam int PHT_WAYS   = BINGO_PHT_WAYS;
  localparam int B_MAXDENSE = BINGO_MAXDENSE;
  localparam int PHTL_W     = 10 + 128;
  localparam int PHTS_W     = 5  + 128;

  typedef enum logic [1:0] { ST_IDLE = 2'd0, ST_PRED = 2'd1, ST_CMT = 2'd2 } fsm_t;

  function automatic logic [7:0] phtl_idx(input logic [15:0] k16);
    return k16[7:0] ^ k16[15:8];
  endfunction
  function automatic logic [6:0] phts_idx(input logic [10:0] p11);
    return p11[6:0] ^ {3'b0, p11[10:7]};
  endfunction
  function automatic logic [2:0] plru4_update(input logic [2:0] p, input logic [1:0] w);
    logic [2:0] n;
    n = p;
    n[0] = ~w[1];
    if (!w[1]) n[1] = ~w[0];
    else       n[2] = ~w[0];
    return n;
  endfunction
  function automatic logic [1:0] plru4_victim(input logic [2:0] p);
    return {p[0], p[0] ? p[2] : p[1]};
  endfunction

  fsm_t        fsm_q, fsm_d;
  logic [19:0] pred_cur_reg_q, pred_cur_reg_d;
  logic [17:0] pred_cur_key_q, pred_cur_key_d;
  logic [11:0] pred_cur_pch_q, pred_cur_pch_d;
  logic [5:0]  pred_cur_off_q, pred_cur_off_d;
  logic [17:0] cmt_cur_key_q, cmt_cur_key_d;
  logic [5:0]  cmt_cur_off_q, cmt_cur_off_d;
  logic [63:0] cmt_cur_mask_q, cmt_cur_mask_d;

  logic [PHT_WAYS-1:0] phtl_v_q [PHTL_SETS];
  logic [2:0]          phtl_plru_q [PHTL_SETS];
  logic [PHT_WAYS-1:0] phts_v_q [PHTS_SETS];
  logic [2:0]          phts_plru_q [PHTS_SETS];

  logic                phtl_rd_en, phts_rd_en;
  logic [7:0]          phtl_rd_idx;
  logic [6:0]          phts_rd_idx;
  logic [PHT_WAYS-1:0] phtl_wr_en, phts_wr_en;
  logic [7:0]          phtl_wr_idx;
  logic [6:0]          phts_wr_idx;
  logic [PHTL_W-1:0]   phtl_wr_data;
  logic [PHTS_W-1:0]   phts_wr_data;
  logic [PHTL_W-1:0]   rd_phtl_q [PHT_WAYS];
  logic [PHT_WAYS-1:0] rd_phtl_v_q;
  logic [PHTS_W-1:0]   rd_phts_q [PHT_WAYS];
  logic [PHT_WAYS-1:0] rd_phts_v_q;

  logic                phtl_plru_we, phts_plru_we;
  logic [7:0]          phtl_plru_idx;
  logic [6:0]          phts_plru_idx;
  logic [2:0]          phtl_plru_wval, phts_plru_wval;

  // 4 independent 1D 1RW SRAM banks per table (standalone ttg_sram_1rw primitive)
  for (genvar w = 0; w < PHT_WAYS; w++) begin : g_phtl_bank
    ttg_sram_1rw #(
      .DEPTH (PHTL_SETS),
      .WIDTH (PHTL_W),
      .MASK_W(1),
      .TAG   ("LLC_BINGO_PHTL")
    ) u_sram (
      .clk  (clk),
      .en   (phtl_wr_en[w] || phtl_rd_en),
      .we   (phtl_wr_en[w]),
      .addr (phtl_wr_en[w] ? phtl_wr_idx : phtl_rd_idx),
      .wdata(phtl_wr_data),
      .wmask(1'b1),
      .rdata(rd_phtl_q[w])
    );
  end
  for (genvar w = 0; w < PHT_WAYS; w++) begin : g_phts_bank
    ttg_sram_1rw #(
      .DEPTH (PHTS_SETS),
      .WIDTH (PHTS_W),
      .MASK_W(1),
      .TAG   ("LLC_BINGO_PHTS")
    ) u_sram (
      .clk  (clk),
      .en   (phts_wr_en[w] || phts_rd_en),
      .we   (phts_wr_en[w]),
      .addr (phts_wr_en[w] ? phts_wr_idx : phts_rd_idx),
      .wdata(phts_wr_data),
      .wmask(1'b1),
      .rdata(rd_phts_q[w])
    );
  end

  // Prediction decode & dense popcount
  logic [9:0]  pred_tag_l;
  logic [4:0]  pred_tag_s;
  logic [7:0]  pred_idx_l;
  logic [6:0]  pred_idx_s;
  logic [PHT_WAYS-1:0] pred_l_eq, pred_s_eq;
  logic        pred_l_hit, pred_s_hit;
  logic [1:0]  pred_l_way, pred_s_way;
  logic [63:0] pred_l_mask, pred_s_mask, pred_s_rot, pred_raw_mask, pred_hit_mask;
  logic [6:0]  pred_dense;

  always_comb begin
    pred_tag_l = pred_cur_key_q[17:8];
    pred_tag_s = pred_cur_pch_q[11:7];
    pred_idx_l = phtl_idx(pred_cur_key_q[15:0]);
    pred_idx_s = phts_idx({pred_cur_pch_q[11:8], pred_cur_pch_q[6:0]});
    for (int w = 0; w < PHT_WAYS; w++) begin
      pred_l_eq[w] = rd_phtl_v_q[w] && (rd_phtl_q[w][137:128] == pred_tag_l);
      pred_s_eq[w] = rd_phts_v_q[w] && (rd_phts_q[w][132:128] == pred_tag_s);
    end
    pred_l_hit = |pred_l_eq;
    pred_l_way = pred_l_eq[0] ? 2'd0 : pred_l_eq[1] ? 2'd1 : pred_l_eq[2] ? 2'd2 : 2'd3;
    pred_s_hit = !pred_l_hit && (|pred_s_eq);
    pred_s_way = pred_s_eq[0] ? 2'd0 : pred_s_eq[1] ? 2'd1 : pred_s_eq[2] ? 2'd2 : 2'd3;
    for (int b = 0; b < 64; b++) begin
      pred_l_mask[b] = (rd_phtl_q[pred_l_way][2*b +: 2] != 2'd0);
      pred_s_mask[b] = (rd_phts_q[pred_s_way][2*b +: 2] != 2'd0);
    end
    pred_s_rot = (pred_cur_off_q == 6'd0) ? pred_s_mask
               : ((pred_s_mask << pred_cur_off_q) | (pred_s_mask >> (7'd64 - {1'b0, pred_cur_off_q})));
    pred_raw_mask = pred_l_hit ? pred_l_mask : (pred_s_hit ? pred_s_rot : 64'd0);
    pred_hit_mask = pred_raw_mask & ~(64'd1 << pred_cur_off_q);
  end
  ttg_popcount #(.N(64)) u_dense_cnt (.bits(pred_raw_mask), .count(pred_dense));

  assign pred_out_v    = (fsm_q == ST_PRED) && (pred_l_hit || pred_s_hit) &&
                         (pred_dense < 7'(B_MAXDENSE)) && (pred_hit_mask != 64'd0);
  assign pred_out_reg  = pred_cur_reg_q;
  assign pred_out_off  = pred_cur_off_q;
  assign pred_out_mask = pred_hit_mask;

  // Commit way-pick & counter RMW
  logic [9:0]  cmt_tag_l;
  logic [4:0]  cmt_tag_s;
  logic [7:0]  cmt_idx_l;
  logic [6:0]  cmt_idx_s;
  logic [11:0] cmt_pch;
  logic [PHT_WAYS-1:0] cmt_l_eq, cmt_s_eq;
  logic        cmt_l_hit, cmt_s_hit;
  logic [1:0]  cmt_l_way, cmt_s_way;
  logic [63:0] cmt_rel_mask;
  logic [PHTL_W-1:0] cmt_l_wdata;
  logic [PHTS_W-1:0] cmt_s_wdata;

  always_comb begin
    cmt_idx_l = phtl_idx(cmt_cur_key_q[15:0]);
    cmt_tag_l = cmt_cur_key_q[17:8];
    cmt_pch   = cmt_cur_key_q[17:6];
    cmt_idx_s = phts_idx({cmt_pch[11:8], cmt_pch[6:0]});
    cmt_tag_s = cmt_pch[11:7];
    for (int w = 0; w < PHT_WAYS; w++) begin
      cmt_l_eq[w] = rd_phtl_v_q[w] && (rd_phtl_q[w][137:128] == cmt_tag_l);
      cmt_s_eq[w] = rd_phts_v_q[w] && (rd_phts_q[w][132:128] == cmt_tag_s);
    end
    cmt_l_hit = |cmt_l_eq;
    if (cmt_l_hit)            cmt_l_way = cmt_l_eq[0] ? 2'd0 : cmt_l_eq[1] ? 2'd1 : cmt_l_eq[2] ? 2'd2 : 2'd3;
    else if (~(&rd_phtl_v_q)) cmt_l_way = !rd_phtl_v_q[0] ? 2'd0 : !rd_phtl_v_q[1] ? 2'd1 : !rd_phtl_v_q[2] ? 2'd2 : 2'd3;
    else                      cmt_l_way = plru4_victim(phtl_plru_q[cmt_idx_l]);

    cmt_s_hit = |cmt_s_eq;
    if (cmt_s_hit)            cmt_s_way = cmt_s_eq[0] ? 2'd0 : cmt_s_eq[1] ? 2'd1 : cmt_s_eq[2] ? 2'd2 : 2'd3;
    else if (~(&rd_phts_v_q)) cmt_s_way = !rd_phts_v_q[0] ? 2'd0 : !rd_phts_v_q[1] ? 2'd1 : !rd_phts_v_q[2] ? 2'd2 : 2'd3;
    else                      cmt_s_way = plru4_victim(phts_plru_q[cmt_idx_s]);

    cmt_rel_mask = (cmt_cur_off_q == 6'd0) ? cmt_cur_mask_q
                 : ((cmt_cur_mask_q >> cmt_cur_off_q) | (cmt_cur_mask_q << (7'd64 - {1'b0, cmt_cur_off_q})));
  end

  always_comb begin
    cmt_l_wdata[137:128] = cmt_tag_l;
    cmt_s_wdata[132:128] = cmt_tag_s;
    for (int b = 0; b < 64; b++) begin
      logic [1:0] cl, cs;
      cl = rd_phtl_q[cmt_l_way][2*b +: 2];
      cs = rd_phts_q[cmt_s_way][2*b +: 2];
      if (!cmt_l_hit)             cmt_l_wdata[2*b +: 2] = cmt_cur_mask_q[b] ? 2'd2 : 2'd0;
      else if (cmt_cur_mask_q[b]) cmt_l_wdata[2*b +: 2] = (cl == 2'd3) ? 2'd3 : (cl + 2'd1);
      else                        cmt_l_wdata[2*b +: 2] = (cl == 2'd0) ? 2'd0 : (cl - 2'd1);
      if (!cmt_s_hit)             cmt_s_wdata[2*b +: 2] = cmt_rel_mask[b] ? 2'd2 : 2'd0;
      else if (cmt_rel_mask[b])   cmt_s_wdata[2*b +: 2] = (cs == 2'd3) ? 2'd3 : (cs + 2'd1);
      else                        cmt_s_wdata[2*b +: 2] = (cs == 2'd0) ? 2'd0 : (cs - 2'd1);
    end
  end

  // FSM control
  always_comb begin
    fsm_d          = fsm_q;
    pred_consume   = 1'b0;
    cmt_pop        = 1'b0;
    pred_cur_reg_d = pred_cur_reg_q;
    pred_cur_key_d = pred_cur_key_q;
    pred_cur_pch_d = pred_cur_pch_q;
    pred_cur_off_d = pred_cur_off_q;
    cmt_cur_key_d  = cmt_cur_key_q;
    cmt_cur_off_d  = cmt_cur_off_q;
    cmt_cur_mask_d = cmt_cur_mask_q;
    phtl_rd_en     = 1'b0; phts_rd_en   = 1'b0;
    phtl_rd_idx    = 8'd0; phts_rd_idx  = 7'd0;
    phtl_wr_en     = '0;   phts_wr_en   = '0;
    phtl_wr_idx    = cmt_idx_l; phts_wr_idx = cmt_idx_s;
    phtl_wr_data   = cmt_l_wdata; phts_wr_data = cmt_s_wdata;
    phtl_plru_we   = 1'b0; phts_plru_we = 1'b0;
    phtl_plru_idx  = 8'd0; phts_plru_idx = 7'd0;
    phtl_plru_wval = 3'd0; phts_plru_wval = 3'd0;

    if (fsm_q == ST_PRED) begin
      if (pred_l_hit) begin
        phtl_plru_we = 1'b1; phtl_plru_idx = pred_idx_l;
        phtl_plru_wval = plru4_update(phtl_plru_q[pred_idx_l], pred_l_way);
      end else if (pred_s_hit) begin
        phts_plru_we = 1'b1; phts_plru_idx = pred_idx_s;
        phts_plru_wval = plru4_update(phts_plru_q[pred_idx_s], pred_s_way);
      end
      fsm_d = ST_IDLE;
    end else if (fsm_q == ST_CMT) begin
      phtl_wr_en[cmt_l_way] = 1'b1;
      phtl_plru_we = 1'b1; phtl_plru_idx = cmt_idx_l;
      phtl_plru_wval = plru4_update(phtl_plru_q[cmt_idx_l], cmt_l_way);
      phts_wr_en[cmt_s_way] = 1'b1;
      phts_plru_we = 1'b1; phts_plru_idx = cmt_idx_s;
      phts_plru_wval = plru4_update(phts_plru_q[cmt_idx_s], cmt_s_way);
      fsm_d = ST_IDLE;
    end else if (pred_pend_v) begin
      phtl_rd_en = 1'b1; phts_rd_en = 1'b1;
      phtl_rd_idx = phtl_idx(pred_pend_key[15:0]);
      phts_rd_idx = phts_idx({pred_pend_pch[11:8], pred_pend_pch[6:0]});
      pred_cur_reg_d = pred_pend_reg; pred_cur_key_d = pred_pend_key;
      pred_cur_pch_d = pred_pend_pch; pred_cur_off_d = pred_pend_off;
      pred_consume = 1'b1;
      fsm_d = ST_PRED;
    end else if (!cmt_empty) begin
      phtl_rd_en = 1'b1; phts_rd_en = 1'b1;
      phtl_rd_idx = phtl_idx(cmt_head_key[15:0]);
      phts_rd_idx = phts_idx({cmt_head_key[17:14], cmt_head_key[12:6]});
      cmt_cur_key_d = cmt_head_key; cmt_cur_off_d = cmt_head_off; cmt_cur_mask_d = cmt_head_mask;
      cmt_pop = 1'b1;
      fsm_d = ST_CMT;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fsm_q       <= ST_IDLE;
      rd_phtl_v_q <= '0;
      rd_phts_v_q <= '0;
      for (int s = 0; s < PHTL_SETS; s++) begin phtl_v_q[s] <= '0; phtl_plru_q[s] <= 3'd0; end
      for (int s = 0; s < PHTS_SETS; s++) begin phts_v_q[s] <= '0; phts_plru_q[s] <= 3'd0; end
    end else begin
      fsm_q <= fsm_d;
      if (phtl_rd_en) rd_phtl_v_q <= phtl_v_q[phtl_rd_idx];
      if (phts_rd_en) rd_phts_v_q <= phts_v_q[phts_rd_idx];
      if (|phtl_wr_en) phtl_v_q[phtl_wr_idx] <= phtl_v_q[phtl_wr_idx] | phtl_wr_en;
      if (|phts_wr_en) phts_v_q[phts_wr_idx] <= phts_v_q[phts_wr_idx] | phts_wr_en;
      if (phtl_plru_we) phtl_plru_q[phtl_plru_idx] <= phtl_plru_wval;
      if (phts_plru_we) phts_plru_q[phts_plru_idx] <= phts_plru_wval;
    end
  end

  always_ff @(posedge clk) begin
    pred_cur_reg_q <= pred_cur_reg_d;
    pred_cur_key_q <= pred_cur_key_d;
    pred_cur_pch_q <= pred_cur_pch_d;
    pred_cur_off_q <= pred_cur_off_d;
    cmt_cur_key_q  <= cmt_cur_key_d;
    cmt_cur_off_q  <= cmt_cur_off_d;
    cmt_cur_mask_q <= cmt_cur_mask_d;
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, pred_cur_pch_q[7], pred_pend_pch[7], pred_pend_key[17:16], cmt_head_key[13]};
endmodule
`default_nettype wire
