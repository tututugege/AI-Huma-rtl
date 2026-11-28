// Ref: front-end/front_top.cpp  FrontChecker::comb (log-depth parallel PdInfo: up to 2 history symbols & 2 RAS ops, pd_nb_base)
`default_nettype none

module front_pd_info import ttg_cfg_pkg::*; import front_pkg::*; import bpu_stage_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    checked,
  input  logic                    flush,
  input  logic                    multi,
  input  logic [4:0]              keep_n,
  input  logic [FETCH_WIDTH-1:0]  seg_first,
  input  logic [XLEN_BITS-1:0]    slot_pc    [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]    ptab_pc    [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  is_rvc,
  input  logic [31:0]             insts      [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  inst_valid,
  input  logic [1:0]              ptype      [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]    pre_target [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  dir_corrected,
  input  logic [FETCH_WIDTH-1:0]  predict_dir,
  input  logic [XLEN_BITS-1:0]    ptab_next,
  output logic                    pd_valid,
  output logic                    pd_flush,
  output logic [1:0]              pd_hn,
  output logic [5:0]              pd_hbits,
  output logic [1:0]              pd_ras_op,
  output logic [XLEN_BITS-1:0]    pd_ras_val,
  output logic [1:0]              pd_ras_op2,
  output logic [XLEN_BITS-1:0]    pd_ras_val2,
  output logic                    pd_nb_valid,
  output logic [XLEN_BITS-1:0]    pd_nb_pc,
  output logic [XLEN_BITS-1:0]    pd_nb_base
);

  // ---- Segment 1 prefix mask & base (parallel) ----
  logic [FETCH_WIDTH-1:0] s1_oh, seg1_ge;
  logic                   any_s1;
  logic [XLEN_BITS-1:0]   seg1_base;

  ttg_first_set #(.N(FETCH_WIDTH)) u_s1 (.req(seg_first), .onehot(s1_oh), .any(any_s1));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_s1_base (.sel(s1_oh), .data(ptab_pc), .out(seg1_base));

  always_comb begin
    seg1_ge = s1_oh;
    seg1_ge = seg1_ge | (seg1_ge << 1);
    seg1_ge = seg1_ge | (seg1_ge << 2);
    seg1_ge = seg1_ge | (seg1_ge << 4);
    seg1_ge = seg1_ge | (seg1_ge << 8);
  end

  // ---- False-branch detection (parallel ttg_first_set) ----
  logic [FETCH_WIDTH-1:0] nb_req, nb_oh;
  logic                   nb_any_raw, nb_any;
  logic [XLEN_BITS-1:0]   nb_pc_sel, nb_pc_d, nb_base_d;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++)
      nb_req[i] = flush && inst_valid[i] && predict_dir[i] && (ptype[i] == PREDECODE_NON_BRANCH);
  end
  ttg_first_set #(.N(FETCH_WIDTH)) u_nb (.req(nb_req), .onehot(nb_oh), .any(nb_any_raw));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_nb_pc (.sel(nb_oh), .data(slot_pc), .out(nb_pc_sel));

  assign nb_any    = nb_any_raw;
  assign nb_pc_d   = nb_any_raw ? nb_pc_sel : '0;
  assign nb_base_d = (nb_any_raw && multi) ? ((|(nb_oh & seg1_ge)) ? seg1_base : ptab_pc[0]) : '0;

  // ---- Parallel per-lane symbol & RAS op, then single ttg_pick_k(K=2) ----
  logic [FETCH_WIDTH-1:0] ctrl_tk, tk_oh [2], tk1_oh, tk2_oh;
  logic [1:0]             tk_v;
  logic                   tk1_any, tk2_any;
  logic [HSYM_W-1:0]      lane_sym  [FETCH_WIDTH];
  logic [1:0]             lane_rop  [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   lane_rval [FETCH_WIDTH];

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      logic [XLEN_BITS-1:0] tgt;
      ctrl_tk[i] = flush && (!multi || (5'(i) < keep_n)) &&
                   inst_valid[i] && (ptype[i] != PREDECODE_NON_BRANCH) && dir_corrected[i];
      if (ptype[i] == PREDECODE_JALR)
        tgt = (multi && (i + 1 < FETCH_WIDTH) && seg_first[i + 1]) ? slot_pc[i + 1] : ptab_next;
      else
        tgt = pre_target[i];
      lane_sym[i]  = hsym_of(slot_pc[i], tgt);
      lane_rop[i]  = 2'd0;
      lane_rval[i] = '0;
      if ((ptype[i] == PREDECODE_JAL) && (insts[i][11:7] == 5'd1)) begin
        lane_rop[i]  = 2'd1;
        lane_rval[i] = slot_pc[i] + (is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4));
      end else if ((ptype[i] == PREDECODE_JALR) && (insts[i][11:7] == 5'd0) &&
                   (insts[i][19:15] == 5'd1) && (insts[i][31:20] == 12'd0)) begin
        lane_rop[i] = 2'd2;
      end
    end
  end

  ttg_pick_k #(.N(FETCH_WIDTH), .K(2)) u_tk (.req(ctrl_tk), .pick_oh(tk_oh), .valid(tk_v));
  assign tk1_oh  = tk_oh[0];
  assign tk1_any = tk_v[0];
  assign tk2_oh  = multi ? tk_oh[1] : '0;
  assign tk2_any = multi && tk_v[1];

  logic [HSYM_W-1:0]    sym1, sym2;
  logic [1:0]           rop1, rop2, hn_d, ras_op_d, ras_op2_d;
  logic [5:0]           hbits_d;
  logic [XLEN_BITS-1:0] rval1, rval2, ras_val_d, ras_val2_d;

  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(HSYM_W))    u_sym1  (.sel(tk1_oh), .data(lane_sym),  .out(sym1));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(2))         u_rop1  (.sel(tk1_oh), .data(lane_rop),  .out(rop1));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_rval1 (.sel(tk1_oh), .data(lane_rval), .out(rval1));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(HSYM_W))    u_sym2  (.sel(tk2_oh), .data(lane_sym),  .out(sym2));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(2))         u_rop2  (.sel(tk2_oh), .data(lane_rop),  .out(rop2));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_rval2 (.sel(tk2_oh), .data(lane_rval), .out(rval2));

  always_comb begin
    hn_d       = tk2_any ? 2'd2 : tk1_any ? 2'd1 : 2'd0;
    hbits_d    = {tk2_any ? sym2 : 3'd0, tk1_any ? sym1 : 3'd0};
    ras_op_d   = 2'd0;
    ras_val_d  = '0;
    ras_op2_d  = 2'd0;
    ras_val2_d = '0;
    if (tk1_any && (rop1 != 2'd0)) begin
      ras_op_d  = rop1;
      ras_val_d = rval1;
      if (tk2_any && (rop2 != 2'd0)) begin
        ras_op2_d  = rop2;
        ras_val2_d = rval2;
      end
    end else if (tk2_any && (rop2 != 2'd0)) begin
      ras_op_d  = rop2;
      ras_val_d = rval2;
    end
  end

  logic                 pd_valid_q, pd_flush_q, pd_nb_valid_q;
  logic [1:0]           pd_hn_q, pd_ras_op_q, pd_ras_op2_q;
  logic [5:0]           pd_hbits_q;
  logic [XLEN_BITS-1:0] pd_ras_val_q, pd_ras_val2_q, pd_nb_pc_q, pd_nb_base_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pd_valid_q    <= 1'b0;
      pd_flush_q    <= 1'b0;
      pd_hn_q       <= 2'd0;
      pd_hbits_q    <= 6'd0;
      pd_ras_op_q   <= 2'd0;
      pd_ras_val_q  <= '0;
      pd_ras_op2_q  <= 2'd0;
      pd_ras_val2_q <= '0;
      pd_nb_valid_q <= 1'b0;
      pd_nb_pc_q    <= '0;
      pd_nb_base_q  <= '0;
    end else begin
      pd_valid_q    <= checked;
      pd_flush_q    <= flush;
      pd_hn_q       <= hn_d;
      pd_hbits_q    <= hbits_d;
      pd_ras_op_q   <= ras_op_d;
      pd_ras_val_q  <= ras_val_d;
      pd_ras_op2_q  <= ras_op2_d;
      pd_ras_val2_q <= ras_val2_d;
      pd_nb_valid_q <= nb_any;
      pd_nb_pc_q    <= nb_pc_d;
      pd_nb_base_q  <= nb_base_d;
    end
  end

  assign pd_valid    = pd_valid_q;
  assign pd_flush    = pd_flush_q;
  assign pd_hn       = pd_hn_q;
  assign pd_hbits    = pd_hbits_q;
  assign pd_ras_op   = pd_ras_op_q;
  assign pd_ras_val  = pd_ras_val_q;
  assign pd_ras_op2  = pd_ras_op2_q;
  assign pd_ras_val2 = pd_ras_val2_q;
  assign pd_nb_valid = pd_nb_valid_q;
  assign pd_nb_pc    = pd_nb_pc_q;
  assign pd_nb_base  = pd_nb_base_q;

  logic unused_pd;
  assign unused_pd = any_s1;

endmodule

`default_nettype wire
